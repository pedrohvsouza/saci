require "socket"
require "./cable"

module Saci
  module Cable
    # Same-host wake transport for `DbServer` (SQLite, MySQL and
    # PostgreSQL in polling mode).
    #
    # Every server owns one UDP socket bound to `0.0.0.0:<port>` with
    # `SO_REUSEADDR`; several processes on one host may bind the same port.
    # `#signal` sends a tiny datagram to `127.255.255.255:<port>`, which the
    # kernel copies to every socket bound to that port, so a broadcast in
    # one process wakes the pollers of the others without a shard or an
    # external service.
    #
    # The port is derived deterministically from the wake key (see
    # `#port_for`), so every process of an app agrees on it. Pass
    # `wake_key:` to `DbServer` to namespace apps that share a host, or
    # `wake_port:` to pin the port. Delivery is best effort: a dropped
    # datagram only delays a message until the next poll, which remains the
    # correctness guarantee. Loopback broadcast can be blocked in some
    # sandboxes; `DbServer` then logs and keeps polling.
    #
    # `#signal` datagrams carry the sender's id, so a server ignores its own
    # wake-ups (it already delivered locally). Each received datagram calls
    # the callback, but `DbServer#wake` collapses wake-ups that arrive while
    # one is pending, so a burst costs one poll, not one per message.
    class LocalWake
      # Loopback subnet broadcast: received by sockets on this host only.
      BROADCAST_ADDRESS = "127.255.255.255"

      # Datagram prefix, followed by the sender id.
      MAGIC = "saci-cable-wake:1:"

      # Ports below the Linux ephemeral range (32768..60999), so an
      # unrelated outgoing connection cannot steal a wake port.
      PORT_BASE    = 24_500
      PORT_SPAN    =  2_000
      MAX_DATAGRAM =     64

      getter key : String
      getter port : Int32

      @closed : Atomic(Bool)
      @reported : Atomic(Bool)
      @fiber : Fiber
      @socket : UDPSocket
      @destination : Socket::IPAddress
      @id : String

      def initialize(@key : String, port : Int32? = nil,
                     @on_wake : Proc(Nil) = -> { }, id : String = Random::Secure.hex(8))
        @port = port || self.class.port_for(@key)
        raise ArgumentError.new("local wake port out of range: #{@port}") unless 1 <= @port <= 65_535
        @id = id
        @closed = Atomic(Bool).new(false)
        @reported = Atomic(Bool).new(false)
        @destination = Socket::IPAddress.new(BROADCAST_ADDRESS, @port)
        @socket = UDPSocket.new
        begin
          # SO_REUSEADDR lets every process on the host bind the same port;
          # broadcast datagrams are then delivered to all of them.
          @socket.reuse_address = true
          @socket.broadcast = true
          @socket.bind("0.0.0.0", @port)
        rescue ex
          begin
            @socket.close
          rescue
          end
          raise ex
        end
        @fiber = spawn(name: "saci-cable-wake") { receive_loop }
      end

      # Deterministic port for a wake key. Stable across processes (FNV-1a,
      # unlike `String#hash`, which is seeded per process).
      def self.port_for(key : String) : Int32
        PORT_BASE + (hash_key(key) % PORT_SPAN).to_i
      end

      private def self.hash_key(key : String) : UInt32
        hash = 2_166_136_261_u32
        key.each_byte do |byte|
          hash ^= byte.to_u32
          hash &*= 16_777_619_u32
        end
        hash
      end

      def closed? : Bool
        @closed.get
      end

      # Tells every other `LocalWake` bound to this key/port that there is
      # something new to poll. Never raises: a failed send degrades to the
      # polling fallback and is reported once.
      def signal : Nil
        return if @closed.get
        @socket.send("#{MAGIC}#{@id}", @destination)
      rescue ex
        report_once(ex) unless @closed.get
      end

      # Stops the receiver and closes the socket (idempotent). Closing the
      # socket wakes the blocked `receive`, so shutdown is immediate and the
      # receiver never spins on a timeout.
      def close : Nil
        return if @closed.swap(true)
        begin
          @socket.close
        rescue
        end
        # Never wait on ourselves: the callback may close the server.
        return if Fiber.current.same?(@fiber)
        deadline = Time.instant + 1.second
        while !@fiber.dead? && Time.instant < deadline
          sleep 1.millisecond
        end
      end

      private def receive_loop : Nil
        loop do
          break if @closed.get
          packet = @socket.receive(MAX_DATAGRAM)
          next unless foreign_packet?(packet[0])
          begin
            @on_wake.call
          rescue ex
            report_once(ex)
          end
        end
      rescue ex : IO::Error
        # A closed socket (normal shutdown) or a socket error ends the
        # receiver; polling remains.
        report_once(ex) unless @closed.get
      rescue ex
        report_once(ex) unless @closed.get
      end

      # Only datagrams from another server of this key count: our own
      # broadcast arrives on our own socket too.
      private def foreign_packet?(payload : String) : Bool
        return false unless payload.starts_with?(MAGIC)
        rest = payload.byte_slice(MAGIC.bytesize)
        rest != @id && !rest.empty?
      end

      private def report_once(ex : Exception) : Nil
        return if @reported.swap(true)
        Cable.report_error(ex, "local wake")
      end
    end
  end
end
