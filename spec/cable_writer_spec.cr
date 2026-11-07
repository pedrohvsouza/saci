require "spec"
require "../src/saci"

# Decodes unmasked server text frames written by HTTP::WebSocket into `io`.
private def cable_writer_frames(io : IO::Memory) : Array(String)
  bytes = io.to_slice
  frames = [] of String
  i = 0
  while i < bytes.size
    len = (bytes[i + 1] & 0x7f).to_i
    offset = 2
    if len == 126
      len = (bytes[i + 2].to_i << 8) | bytes[i + 3].to_i
      offset = 4
    end
    frames << String.new(bytes[i + offset, len])
    i += offset + len
  end
  frames
end

private def cable_writer_wait(timeout = 5.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out" if Time.instant > deadline
    sleep 1.millisecond
  end
end

describe "Saci::Cable::Connection writer" do
  it "keeps no writer fiber while idle and preserves per-producer order" do
    io = IO::Memory.new
    server = Saci::Cable::Server.new
    connection = Saci::Cable::Connection.new(HTTP::WebSocket.new(io), Saci::Params.new, server, message_buffer_size: 4096)
    connection.writer_running?.should be_false

    producers = 8
    per = 150
    done = Channel(Nil).new(producers)
    {% if flag?(:execution_context) %}
      ctx = Fiber::ExecutionContext::Parallel.new("writer-spec", 4)
    {% end %}
    producers.times do |p|
      work = -> do
        per.times do |n|
          connection.send_raw(%({"p":#{p},"n":#{n}}))
          Fiber.yield if n % 7 == 0
        end
        done.send(nil)
      end
      {% if flag?(:execution_context) %}
        ctx.spawn { work.call }
      {% else %}
        spawn { work.call }
      {% end %}
    end
    producers.times { done.receive }
    connection.flush(5.seconds)
    cable_writer_wait { !connection.writer_running? }

    frames = cable_writer_frames(io).map { |f| JSON.parse(f) }
    frames.size.should eq(producers * per)
    producers.times do |p|
      frames.select { |f| f["p"].as_i == p }.map(&.["n"].as_i).should eq((0...per).to_a)
    end
    connection.closed?.should be_false
  end

  it "wakes up again for new frames and still flushes them before closing" do
    io = IO::Memory.new
    server = Saci::Cable::Server.new
    connection = Saci::Cable::Connection.new(HTTP::WebSocket.new(io), Saci::Params.new, server)
    connection.send_raw(%("a"))
    connection.flush
    cable_writer_wait { !connection.writer_running? }
    connection.send_raw(%("b"))
    connection.send_raw(%("c"))
    connection.close
    cable_writer_wait { connection.closed? && !connection.writer_running? }
    cable_writer_frames(io).first(3).should eq([%("a"), %("b"), %("c")])
  end
end

private def cable_trim_deep(depth : Int32) : Int64
  buf = uninitialized UInt8[1024]
  buf.to_slice.fill(depth.to_u8!)
  return buf[0].to_i64 if depth == 0
  cable_trim_deep(depth - 1) + buf[1].to_i64
end

describe "Saci::Cable.trim_fiber_stack" do
  it "releases pages below the stack pointer and the fiber keeps working" do
    result = Channel({Int64, Int64, Int64}).new(1)
    spawn do
      before = cable_trim_deep(250) # ~256 KiB of stack touched
      released = Saci::Cable.trim_fiber_stack
      after = cable_trim_deep(250) # pages fault back in, zeroed then rewritten
      result.send({before, released, after})
    end
    before, released, after = result.receive
    released.should be > 200_000
    after.should eq(before)
  end

  it "does nothing on the main fiber" do
    Saci::Cable.trim_fiber_stack.should eq(0)
  end
end

describe "Saci::Cable.run_detached" do
  it "runs on the bounded pool, re-raises failures and runs nested calls inline" do
    names = [] of String?
    Saci::Cable.run_detached { names << Fiber.current.name }
    names.should eq([Saci::Cable::DetachedPool::FIBER_NAME])

    expect_raises(Exception, "boom") { Saci::Cable.run_detached { raise "boom" } }

    nested = false
    Saci::Cable.run_detached { Saci::Cable.run_detached { nested = true } }
    nested.should be_true
  end

  it "queues work beyond the pool size instead of spawning more fibers" do
    size = Saci::Cable.detached_pool.size
    gate = Channel(Nil).new
    running = Atomic(Int32).new(0)
    peak = Atomic(Int32).new(0)
    finished = Channel(Nil).new(size * 2)
    (size * 2).times do
      spawn do
        Saci::Cable.run_detached do
          now = running.add(1) + 1
          peak.max(now)
          gate.receive
          running.sub(1)
        end
        finished.send(nil)
      end
    end
    cable_writer_wait { running.get == size }
    sleep 10.milliseconds
    peak.get.should eq(size)
    (size * 2).times { gate.send(nil) }
    (size * 2).times { finished.receive }
  end
end
