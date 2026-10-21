module Saci
  module Storage
    # Pure-Crystal metadata extraction for common media containers.
    #
    # No image library is required: PNG/GIF/JPEG/WebP dimensions are read
    # from the file headers, so `Blob#analyze` works on a stock Crystal
    # install. Video/audio duration is a documented placeholder (`0`) —
    # plug in `ffprobe` in application code if you need it.
    module Analysis
      # Returns a string-keyed metadata hash. Recognised keys:
      # `width`, `height` (images) and `duration` (video/audio placeholder).
      def self.analyze(data : Bytes, content_type : String? = nil) : Hash(String, Int32)
        result = {} of String => Int32
        if dimensions = image_dimensions(data)
          result["width"] = dimensions[0]
          result["height"] = dimensions[1]
        end
        ct = content_type.try(&.downcase)
        if ct && (ct.starts_with?("video/") || ct.starts_with?("audio/"))
          result["duration"] = 0
        end
        result
      end

      # `{width, height}` or nil when the bytes are not a recognised image.
      def self.image_dimensions(data : Bytes) : Tuple(Int32, Int32)?
        png_dimensions(data) || gif_dimensions(data) || jpeg_dimensions(data) || webp_dimensions(data)
      end

      def self.image?(content_type : String?) : Bool
        ct = content_type.try(&.downcase) || ""
        ct.starts_with?("image/") && !ct.includes?("svg")
      end

      private def self.png_dimensions(data : Bytes) : Tuple(Int32, Int32)?
        return nil if data.size < 24
        signature = [0x89_u8, 0x50_u8, 0x4e_u8, 0x47_u8, 0x0d_u8, 0x0a_u8, 0x1a_u8, 0x0a_u8]
        return nil unless (0...8).all? { |i| data[i] == signature[i] }
        return nil unless String.new(data[12, 4]) == "IHDR"
        {read_u32_be(data, 16).to_i32, read_u32_be(data, 20).to_i32}
      end

      private def self.gif_dimensions(data : Bytes) : Tuple(Int32, Int32)?
        return nil if data.size < 10
        header = String.new(data[0, 6])
        return nil unless header == "GIF87a" || header == "GIF89a"
        {read_u16_le(data, 6).to_i32, read_u16_le(data, 8).to_i32}
      end

      private def self.jpeg_dimensions(data : Bytes) : Tuple(Int32, Int32)?
        return nil if data.size < 4
        return nil unless data[0] == 0xff_u8 && data[1] == 0xd8_u8
        index = 2
        while index + 8 < data.size
          # Skip fill bytes.
          while index < data.size && data[index] != 0xff_u8
            index += 1
          end
          while index < data.size && data[index] == 0xff_u8
            index += 1
          end
          break if index >= data.size
          marker = data[index]
          index += 1
          # Standalone markers: TEM, RST0-7.
          next if marker == 0x01_u8 || (0xd0_u8 <= marker <= 0xd7_u8)
          break if index + 1 >= data.size
          segment_size = read_u16_be(data, index).to_i32
          break if segment_size < 2
          # SOF0..SOF15 except DHT (0xc4), JPG (0xc8), DAC (0xcc).
          if 0xc0_u8 <= marker <= 0xcf_u8 && ![0xc4_u8, 0xc8_u8, 0xcc_u8].includes?(marker)
            return nil if index + 7 >= data.size
            height = read_u16_be(data, index + 3).to_i32
            width = read_u16_be(data, index + 5).to_i32
            return {width, height}
          end
          index += segment_size
        end
        nil
      end

      private def self.webp_dimensions(data : Bytes) : Tuple(Int32, Int32)?
        return nil if data.size < 30
        return nil unless String.new(data[0, 4]) == "RIFF" && String.new(data[8, 4]) == "WEBP"
        chunk = String.new(data[12, 4])
        case chunk
        when "VP8X"
          # 24-bit little-endian width-1 / height-1, starting at byte 24.
          width = read_u24_le(data, 24) + 1
          height = read_u24_le(data, 27) + 1
          {width, height}
        when "VP8L"
          return nil if data.size < 25
          bits = read_u32_le(data, 21)
          {((bits & 0x3fff_u32) + 1).to_i32, (((bits >> 14) & 0x3fff_u32) + 1).to_i32}
        when "VP8 "
          # Lossy WebP: search for the 9d 01 2a start code.
          index = 20
          while index + 9 < data.size
            if data[index] == 0x9d_u8 && data[index + 1] == 0x01_u8 && data[index + 2] == 0x2a_u8
              width = read_u16_le(data, index + 3).to_i32 & 0x3fff
              height = read_u16_le(data, index + 5).to_i32 & 0x3fff
              return {width, height}
            end
            index += 1
          end
          nil
        else
          nil
        end
      end

      private def self.read_u16_be(data : Bytes, offset : Int32) : UInt16
        ((data[offset].to_u16 << 8) | data[offset + 1].to_u16)
      end

      private def self.read_u16_le(data : Bytes, offset : Int32) : UInt16
        (data[offset].to_u16 | (data[offset + 1].to_u16 << 8))
      end

      private def self.read_u24_le(data : Bytes, offset : Int32) : Int32
        (data[offset].to_i32 | (data[offset + 1].to_i32 << 8) | (data[offset + 2].to_i32 << 16))
      end

      private def self.read_u32_be(data : Bytes, offset : Int32) : UInt32
        (data[offset].to_u32 << 24) | (data[offset + 1].to_u32 << 16) |
          (data[offset + 2].to_u32 << 8) | data[offset + 3].to_u32
      end

      private def self.read_u32_le(data : Bytes, offset : Int32) : UInt32
        data[offset].to_u32 | (data[offset + 1].to_u32 << 8) |
          (data[offset + 2].to_u32 << 16) | (data[offset + 3].to_u32 << 24)
      end
    end
  end
end
