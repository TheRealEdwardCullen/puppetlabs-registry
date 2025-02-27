require 'puppet/type'
begin
  require "puppet_x/puppetlabs/registry"
rescue LoadError => detail
  require "pathname" # JJM WORK_AROUND #14073 and #7788
  module_base = Pathname.new(__FILE__).dirname + "../../../"
  require module_base + "puppet_x/puppetlabs/registry"
end

Puppet::Type.type(:registry_value).provide(:registry) do
  include Puppet::Util::Windows::Registry if Puppet.features.microsoft_windows?

  defaultfor :operatingsystem => :windows
  confine    :operatingsystem => :windows

  def self.instances
    []
  end

  def hive
    PuppetX::Puppetlabs::Registry.hkeys[path.root]
  end

  def access
    path.access
  end

  def subkey
    path.subkey
  end

  def exists?
    Puppet.debug("Checking the existence of registry value: #{self}")
    found = false
    begin
      hive.open(subkey, Win32::Registry::KEY_READ | access) do |reg|
        FFI::Pointer.from_string_to_wide_string(valuename) do |valuename_ptr|
          status = Puppet::Util::Windows::Registry.RegQueryValueExW(reg.hkey, valuename_ptr,
            FFI::MemoryPointer::NULL, FFI::MemoryPointer::NULL,
            FFI::MemoryPointer::NULL, FFI::MemoryPointer::NULL)

          found = status == 0
          Puppet.debug((found ? "Found" : "Didn't find") + " registry value: #{self}")
          raise Win32::Registry::Error.new(status) if !found
        end
      end
    rescue Win32::Registry::Error => detail
      case detail.code
      when 2
        # Code 2 is the error message for "The system cannot find the file specified."
        # http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382.aspx
        found = false
      else
        error = Puppet::Error.new("Unexpected exception from Win32 API. detail: (#{detail.message}) ERROR CODE: #{detail.code}. Puppet Error ID: D4B679E4-0E22-48D5-80EF-96AAEC0282B9")
        error.set_backtrace detail.backtrace
        raise error
      end
    end
    found
  end

  def create
    Puppet.debug("Creating registry value: #{self}")
    write_value
  end

  def flush
    # REVISIT - This concept of flush seems different than package provider's
    # concept of flush.
    Puppet.debug("Flushing registry value: #{self}")
    return if resource[:ensure] == :absent
    write_value
  end

  def destroy
    Puppet.debug("Destroying registry value: #{self}")
    hive.open(subkey, Win32::Registry::KEY_ALL_ACCESS | access) { |reg| self.delete_value(reg, valuename) }
  end

  def type
    regvalue[:type] || :absent
  end

  def type=(value)
    regvalue[:type] = value
  end

  def data
    regvalue[:data] || :absent
  end

  def data=(value)
    regvalue[:data] = value
  end

  def regvalue
    unless @regvalue
      @regvalue = {}
      hive.open(subkey, Win32::Registry::KEY_READ | access) do |reg|
        FFI::Pointer.from_string_to_wide_string(valuename) do |valuename_ptr|
          type_ptr = FFI::MemoryPointer.new(:uint32)
          if Puppet::Util::Windows::Registry.RegQueryValueExW(
            reg.hkey, valuename_ptr,
            FFI::MemoryPointer::NULL, type_ptr,
            FFI::MemoryPointer::NULL, FFI::MemoryPointer::NULL
          ) == 0
            contents = [type_ptr.read(:uint32), nil]
            begin
              # Note - This actually calls read from Win32::Registry not Puppet::Util::Windows::Registry
              contents = reg.read(valuename)
            rescue Encoding::InvalidByteSequenceError => e
              Puppet.log_exception(e, "#{self}: #{e} when reading registry value")
            end
            @regvalue[:type], @regvalue[:data] = from_native(contents)
          end
        end
      end
    end
    @regvalue
  end

  # convert puppet type and data to native
  def to_native(ptype, pdata)
    # JJM Because the data property is set to :array_matching => :all we
    # should always get an array from Puppet.  We need to convert this
    # array to something usable by the Win API.
    raise Puppet::Error, "Data should be an Array (ErrorID 37D9BBAB-52E8-4A7C-9F2E-D7BF16A59050)" unless pdata.kind_of?(Array)
    ndata =
      case ptype
      when :binary
        pdata.first.scan(/[a-f\d]{2}/i).map{ |byte| [byte].pack('H2') }.join('')
      when :array
        # We already have an array, and the native API write method takes an
        # array, so send it thru.
        pdata
      else
        # Since we have an array, take the first element and send it to the
        # native API which is expecting a scalar.
        pdata.first
      end

    return [PuppetX::Puppetlabs::Registry.name2type(ptype), ndata]
  end

  # convert from native type and data to puppet
  def from_native(ary)
    ntype, ndata = ary

    pdata =
      case PuppetX::Puppetlabs::Registry.type2name(ntype)
      when :binary
        ndata.bytes.map{ |byte| "%02x" % byte }.join(' ')
      when :array
        # We get the data from the registry in Array form.
        ndata
      else
        ndata
      end

    # JJM Since the data property is set to :array_matching => all we should
    # always give an array to Puppet.  This is why we have the ternary operator
    # I'm not calling .to_a because Ruby issues a warning about the default
    # implementation of to_a going away in the future.
    return [PuppetX::Puppetlabs::Registry.type2name(ntype), pdata.kind_of?(Array) ? pdata : [pdata]]
  end

  private

  def write_value
    begin
      hive.open(subkey, Win32::Registry::KEY_ALL_ACCESS | access) do |reg|
        ary = to_native(resource[:type], resource[:data])
        write(reg, valuename, ary[0], ary[1])
      end
    rescue Win32::Registry::Error => detail
      error = case detail.code
      when 2
        # Code 2 is the error message for "The system cannot find the file specified."
        # http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382.aspx
        Puppet::Error.new("Cannot write to the registry. The parent key does not exist. detail: (#{detail.message}) Puppet Error ID: AC99C7C6-98D6-4E91-A75E-970F4064BF95")
      else
        Puppet::Error.new("Unexpected exception from Win32 API. detail: (#{detail.message}). ERROR CODE: #{detail.code}. Puppet Error ID: F46C6AE2-C711-48F9-86D6-5D50E1988E48")
      end
      error.set_backtrace detail.backtrace
      raise error
    end
  end

  def data_to_bytes(type, data)
    bytes = []

    case type
      when Win32::Registry::REG_SZ, Win32::Registry::REG_EXPAND_SZ
        bytes = Puppet::Util::Windows::String.wide_string(data).bytes.to_a
      when Win32::Registry::REG_MULTI_SZ
        # each wide string is already NULL terminated
        bytes = data.map { |s| Puppet::Util::Windows::String.wide_string(s).bytes.to_a }.flat_map { |a| a }
        # requires an additional NULL terminator to terminate properly
        bytes << 0 << 0
      when Win32::Registry::REG_BINARY
        bytes = data.bytes.to_a
      when Win32::Registry::REG_DWORD
        # L is 32-bit unsigned native (little) endian order
        bytes = [data].pack('L').unpack('C*')
      when Win32::Registry::REG_QWORD
        # Q is 64-bit unsigned native (little) endian order
        bytes = [data].pack('Q').unpack('C*')
      else
        raise TypeError, "Unsupported type #{type}"
    end

    bytes
  end

  def write(reg, name, type, data)
    FFI::Pointer.from_string_to_wide_string(valuename) do |name_ptr|
      bytes = data_to_bytes(type, data)
      FFI::MemoryPointer.new(:uchar, bytes.length) do |data_ptr|
        data_ptr.write_array_of_uchar(bytes)
        if RegSetValueExW(reg.hkey, name_ptr, 0,
          type, data_ptr, data_ptr.size) != 0
            raise Puppet::Util::Windows::Error.new("Failed to write registry value")
        end
      end
    end
  end

  if Puppet.features.microsoft_windows?
    require 'ffi'
    extend FFI::Library
    # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724923(v=vs.85).aspx
    # LONG WINAPI RegSetValueEx(
    #   _In_             HKEY    hKey,
    #   _In_opt_         LPCTSTR lpValueName,
    #   _Reserved_       DWORD   Reserved,
    #   _In_             DWORD   dwType,
    #   _In_       const BYTE    *lpData,
    #   _In_             DWORD   cbData
    # );
    ffi_lib :advapi32
    attach_function :RegSetValueExW,
      [:handle, :pointer, :dword, :dword, :pointer, :dword], :win32_long
  end

  def valuename
    path.valuename
  end

  def path
    @path ||= PuppetX::Puppetlabs::Registry::RegistryValuePath.new(resource.parameter(:path).value)
  end
end
