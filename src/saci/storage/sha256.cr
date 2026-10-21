module Saci
  module Storage
    # Minimal pure-Crystal SHA-256.
    #
    # The framework deliberately avoids stdlib `Digest::*` (it links
    # OpenSSL symbols removed in OpenSSL >= 3.2, so binaries built on
    # modern systems fail to link). Storage needs SHA-256 for checksums
    # and AWS SigV4, so it ships this tiny implementation instead.
    module SHA256
      K = [
        0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32,
        0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
        0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32,
        0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
        0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32,
        0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
        0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32,
        0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
        0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32,
        0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
        0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32,
        0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
        0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32,
        0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
        0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32,
        0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
      ] of UInt32

      def self.hexdigest(data : Bytes | String) : String
        digest(data).hexstring
      end

      def self.digest(data : Bytes | String) : Bytes
        bytes = data.is_a?(String) ? data.to_slice : data
        h = [
          0x6a09e667_u32, 0xbb67ae85_u32, 0x3c6ef372_u32, 0xa54ff53a_u32,
          0x510e527f_u32, 0x9b05688c_u32, 0x1f83d9ab_u32, 0x5be0cd19_u32,
        ] of UInt32

        message = Array(UInt8).new(bytes.size + 9)
        bytes.each { |byte| message << byte }
        message << 0x80_u8
        pad = (56 - message.size % 64) % 64
        pad.times { message << 0_u8 }
        bit_len = (bytes.size.to_u64 * 8_u64)
        8.times do |i|
          message << ((bit_len >> ((7 - i) * 8)) & 0xff).to_u8
        end

        w = Array(UInt32).new(64, 0_u32)
        offset = 0
        while offset < message.size
          (0...16).each do |i|
            j = offset + i * 4
            w[i] = (message[j].to_u32 << 24) | (message[j + 1].to_u32 << 16) |
                   (message[j + 2].to_u32 << 8) | message[j + 3].to_u32
          end
          (16...64).each do |i|
            s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
          end

          a, b, c, d, e, f, g, hh = h
          (0...64).each do |i|
            s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            ch = (e & f) ^ ((~e) & g)
            temp1 = hh &+ s1 &+ ch &+ K[i] &+ w[i]
            s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = s0 &+ maj

            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
          end

          h[0] &+= a
          h[1] &+= b
          h[2] &+= c
          h[3] &+= d
          h[4] &+= e
          h[5] &+= f
          h[6] &+= g
          h[7] &+= hh
          offset += 64
        end

        Bytes.new(32) do |i|
          word = h[i // 4]
          ((word >> ((3 - (i % 4)) * 8)) & 0xff).to_u8
        end
      end

      private def self.rotr(value : UInt32, bits : Int32) : UInt32
        (value >> bits) | (value << (32 - bits))
      end
    end
  end
end
