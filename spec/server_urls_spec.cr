require "spec"
require "../src/saci/server_urls"

describe Saci::ServerUrls do
  it "lists Local and Network URLs when bound to every interface" do
    banner = Saci::ServerUrls.banner("0.0.0.0", 3000, ["192.168.15.10", "10.8.0.2"])
    banner.should eq <<-TEXT
      Saci listening on:
        Local:   http://localhost:3000/
        Network: http://192.168.15.10:3000/
        Network: http://10.8.0.2:3000/

      TEXT
    Saci::ServerUrls.banner("::", 8080, [] of String).should contain("Network: no network interface found")
  end

  it "explains how to expose a loopback-only server" do
    banner = Saci::ServerUrls.banner("127.0.0.1", 3000)
    banner.should contain("Local:   http://localhost:3000/")
    banner.should contain("saci serve --host")
  end

  it "shows a specific address as is" do
    Saci::ServerUrls.banner("192.168.1.20", 3000).should contain("Network: http://192.168.1.20:3000/")
    Saci::ServerUrls.banner("fe80::1", 3000).should contain("http://[fe80::1]:3000/")
  end

  it "prefers physical interfaces over container and VM bridges" do
    found = [{"docker0", "172.17.0.1"}, {"enp42s0", "192.168.15.10"}, {"br-966054a71632", "172.18.0.1"}, {"wlan0", "192.168.15.11"}]
    Saci::ServerUrls.network_addresses(found).should eq(["192.168.15.10", "192.168.15.11"])
    Saci::ServerUrls.network_addresses([{"docker0", "172.17.0.1"}]).should eq(["172.17.0.1"])
  end

  it "reads this machine's interfaces" do
    {% unless flag?(:win32) %}
      Saci::ServerUrls.interfaces.each do |(name, ip)|
        name.should_not be_empty
        Socket::IPAddress.valid_v4?(ip).should be_true
        ip.starts_with?("127.").should be_false
      end
    {% end %}
  end
end
