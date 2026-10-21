require "compress/zlib"

require "./support"

module Saci
  module Office
    # CRC-32 (IEEE 802.3, polynomial 0xEDB88320) used by ZIP entries.
    #
    # Implemented here rather than pulled from a shard so the office layer
    # stays dependency-free and the checksum is testable in isolation.
    module CRC32
      TABLE = begin
        table = Array(UInt32).new(256, 0_u32)
        256.times do |i|
          crc = i.to_u32
          8.times do
            crc = (crc & 1_u32) != 0 ? 0xEDB88320_u32 ^ (crc >> 1) : crc >> 1
          end
          table[i] = crc
        end
        table
      end

      # Continues a CRC from *crc* (pass 0xFFFFFFFF to start) over *data*.
      def self.update(data : Bytes, crc : UInt32 = 0xFFFFFFFF_u32) : UInt32
        data.each do |byte|
          crc = TABLE[((crc ^ byte) & 0xFF).to_i] ^ (crc >> 8)
        end
        crc
      end

      # Checksum of *data*; matches `Digest::CRC32.checksum`.
      def self.checksum(data : Bytes) : UInt32
        update(data) ^ 0xFFFFFFFF_u32
      end

      def self.checksum(data : String) : UInt32
        checksum(data.to_slice)
      end
    end

    # Minimal ZIP container writer (the same container XLSX uses).
    #
    # Implements the parts of APPNOTE.TXT needed by Office Open XML:
    # local file headers, DEFLATE or STORE payloads, the central directory
    # and the end-of-central-directory record. No ZIP64, encryption,
    # comments or directory entries are emitted; packages are small enough
    # that the classic 32-bit format is sufficient.
    module ZIP
      LOCAL_FILE_HEADER   = 0x04034b50_u32
      CENTRAL_FILE_HEADER = 0x02014b50_u32
      END_OF_CENTRAL_DIR  = 0x06054b50_u32
      UTF8_FLAG           =     0x0800_u16
      VERSION             =         20_u16

      # One central-directory record. The local header is written
      # immediately, but central records are held until `#close`.
      struct Entry
        getter name : String
        getter crc32 : UInt32
        getter compressed_size : UInt32
        getter size : UInt32
        getter method : UInt16
        getter flags : UInt16
        getter dos_time : UInt16
        getter dos_date : UInt16
        getter local_offset : UInt32

        def initialize(@name, @crc32, @compressed_size, @size, @method,
                       @flags, @dos_time, @dos_date, @local_offset)
        end
      end

      class Error < Exception
      end

      class Writer
        getter entries = [] of Entry

        @offset : Int64 = 0
        @closed = false

        # *compression* is `:deflate` (default) or `:store`.
        def initialize(@io : IO, @compression : Symbol = :deflate)
          validate_compression!(@compression)
        end

        # Adds (or replaces) one file. *data* is written as binary; Strings
        # are used as their UTF-8 bytes.
        def add_file(name : String, data : String | Bytes, compression : Symbol? = nil) : Nil
          raise Error.new("ZIP writer is closed") if @closed

          entry_name = normalize_name(name)
          method_symbol = compression || @compression
          validate_compression!(method_symbol)

          bytes = data.is_a?(String) ? data.to_slice : data
          raise Error.new("ZIP entry too large: #{entry_name}") if bytes.size > UInt32::MAX

          method = method_symbol == :store ? 0_u16 : 8_u16
          payload = method == 8_u16 ? deflate(bytes) : bytes
          raise Error.new("ZIP entry too large: #{entry_name}") if payload.size > UInt32::MAX

          crc = CRC32.checksum(bytes)
          flags = entry_name.ascii_only? ? 0_u16 : UTF8_FLAG
          dos_time, dos_date = dos_timestamp(Time.utc)
          local_offset = @offset.to_u32
          compressed_size = payload.size.to_u32
          size = bytes.size.to_u32
          name_length = entry_name.bytesize.to_u16

          emit_u32(LOCAL_FILE_HEADER)
          emit_u16(VERSION)
          emit_u16(flags)
          emit_u16(method)
          emit_u16(dos_time)
          emit_u16(dos_date)
          emit_u32(crc)
          emit_u32(compressed_size)
          emit_u32(size)
          emit_u16(name_length)
          emit_u16(0_u16) # extra field length
          emit(entry_name)
          emit_bytes(payload)

          @entries << Entry.new(
            name: entry_name,
            crc32: crc,
            compressed_size: compressed_size,
            size: size,
            method: method,
            flags: flags,
            dos_time: dos_time,
            dos_date: dos_date,
            local_offset: local_offset,
          )
        end

        # Writes the central directory and EOCD. Safe to call twice.
        def close : Nil
          return if @closed
          @closed = true
          raise Error.new("ZIP64 archives are not supported") if @entries.size > UInt16::MAX

          central_offset = @offset.to_u32
          @entries.each do |entry|
            name_length = entry.name.bytesize.to_u16
            emit_u32(CENTRAL_FILE_HEADER)
            emit_u16(VERSION) # version made by (MS-DOS, 2.0)
            emit_u16(VERSION)
            emit_u16(entry.flags)
            emit_u16(entry.method)
            emit_u16(entry.dos_time)
            emit_u16(entry.dos_date)
            emit_u32(entry.crc32)
            emit_u32(entry.compressed_size)
            emit_u32(entry.size)
            emit_u16(name_length)
            emit_u16(0_u16) # extra
            emit_u16(0_u16) # comment
            emit_u16(0_u16) # disk number start
            emit_u16(0_u16) # internal attributes
            emit_u32(0_u32) # external attributes
            emit_u32(entry.local_offset)
            emit(entry.name)
          end

          central_size = (@offset - central_offset.to_i64).to_u32
          emit_u32(END_OF_CENTRAL_DIR)
          emit_u16(0_u16) # this disk
          emit_u16(0_u16) # central directory disk
          emit_u16(@entries.size.to_u16)
          emit_u16(@entries.size.to_u16)
          emit_u32(central_size)
          emit_u32(central_offset)
          emit_u16(0_u16) # comment length
        end

        # Builds an archive in memory from a yielded writer.
        def self.build(compression : Symbol = :deflate, & : Writer ->) : Bytes
          io = IO::Memory.new
          writer = Writer.new(io, compression)
          yield writer
          writer.close
          io.to_slice
        end

        # ZIP method 8 is *raw* DEFLATE (RFC 1951), not the zlib wrapper
        # (RFC 1950), so use Compress::Deflate directly.
        private def deflate(bytes : Bytes) : Bytes
          output = IO::Memory.new
          compressor = Compress::Deflate::Writer.new(output)
          compressor.write(bytes)
          compressor.close
          output.to_slice
        end

        # ZIP uses MS-DOS timestamps: seconds have 2-second resolution and
        # years outside 1980..2107 cannot be represented (clamped).
        private def dos_timestamp(time : Time) : Tuple(UInt16, UInt16)
          year = time.year.clamp(1980, 2107)
          date = ((year - 1980) << 9) | (time.month << 5) | time.day
          clock = (time.hour << 11) | (time.minute << 5) | (time.second // 2)
          {clock.to_u16, date.to_u16}
        end

        private def validate_compression!(compression : Symbol) : Nil
          unless compression == :store || compression == :deflate
            raise ArgumentError.new("ZIP compression must be :store or :deflate, got #{compression}")
          end
        end

        private def normalize_name(name : String) : String
          normalized = name.gsub('\\', '/').sub(/\A\/+/, "")
          if normalized.empty? || normalized.split('/').any? { |part| part == ".." }
            raise ArgumentError.new("Invalid ZIP entry name: #{name.inspect}")
          end
          if normalized.bytesize > UInt16::MAX
            raise ArgumentError.new("ZIP entry name too long: #{name.inspect}")
          end
          normalized
        end

        private def emit(value : String) : Nil
          @io << value
          @offset += value.bytesize
        end

        private def emit_bytes(value : Bytes) : Nil
          @io.write(value)
          @offset += value.size
        end

        private def emit_u16(value : UInt16) : Nil
          @io.write_bytes(value, IO::ByteFormat::LittleEndian)
          @offset += 2
        end

        private def emit_u32(value : UInt32) : Nil
          @io.write_bytes(value, IO::ByteFormat::LittleEndian)
          @offset += 4
        end
      end
    end
  end
end
