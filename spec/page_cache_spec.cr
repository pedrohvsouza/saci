require "spec"
require "file_utils"
require "../src/saci"

PAGE_CACHE_TEST_ROOT = "/tmp/opencode/saci_page_cache_test"

describe Saci::PageCache do
  before_each do
    Saci::PageCache.root = PAGE_CACHE_TEST_ROOT
    Saci::PageCache.clear!
  end

  after_all do
    Saci::PageCache.reset!
    FileUtils.rm_rf(PAGE_CACHE_TEST_ROOT)
  end

  it "writes and reads a page" do
    Saci::PageCache.write("/stories", "<h1>top</h1>")
    Saci::PageCache.read("/stories").should eq("<h1>top</h1>")
    Saci::PageCache.exists?("/stories").should be_true
  end

  it "misses on unknown paths" do
    Saci::PageCache.read("/nope").should be_nil
    Saci::PageCache.exists?("/nope").should be_false
  end

  it "keys files under the root with .html defaults" do
    file = Saci::PageCache.write("/stories/top", "x")
    file.should eq(File.join(PAGE_CACHE_TEST_ROOT, "stories/top.html"))
    Saci::PageCache.file_for("/").should eq(File.join(PAGE_CACHE_TEST_ROOT, "index.html"))
    Saci::PageCache.file_for("/feed.xml").should end_with("feed.xml")
  end

  it "overwrites on repeat writes" do
    Saci::PageCache.write("/stories", "v1")
    Saci::PageCache.write("/stories", "v2")
    Saci::PageCache.read("/stories").should eq("v2")
  end

  it "expires single entries" do
    Saci::PageCache.write("/stories", "x")
    Saci::PageCache.expire("/stories").should be_true
    Saci::PageCache.read("/stories").should be_nil
    Saci::PageCache.expire("/stories").should be_false
  end

  it "expires whole directories without touching siblings" do
    Saci::PageCache.write("/stories", "root")
    Saci::PageCache.write("/stories/top", "a")
    Saci::PageCache.write("/stories/recent", "b")
    Saci::PageCache.write("/story/1", "sibling")
    Saci::PageCache.expire_dir("/stories").should eq(3)
    Saci::PageCache.read("/stories").should be_nil
    Saci::PageCache.read("/stories/top").should be_nil
    Saci::PageCache.read("/story/1").should eq("sibling")
    Saci::PageCache.expire_dir("/missing").should eq(0)
  end

  it "rejects path traversal" do
    expect_raises(ArgumentError, /'\.\.'/) do
      Saci::PageCache.write("/../evil", "x")
    end
    expect_raises(ArgumentError, /'\.\.'/) do
      Saci::PageCache.read("/stories/../../evil")
    end
  end

  it "fetches write-through" do
    calls = 0
    first = Saci::PageCache.fetch("/cached") { calls += 1; "rendered" }
    second = Saci::PageCache.fetch("/cached") { calls += 1; "rendered-again" }
    first.should eq("rendered")
    second.should eq("rendered")
    calls.should eq(1)
  end

  it "supports a CachePageJob-style render-then-write flow" do
    payload = {"path" => "/stories", "content" => "<h1>job</h1>"}
    Saci::PageCache.write(payload["path"], payload["content"])
    Saci::PageCache.read("/stories").should eq("<h1>job</h1>")
    Saci::PageCache.expire(payload["path"]).should be_true
  end
end
