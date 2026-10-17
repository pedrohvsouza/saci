require "spec"
require "file"
require "../src/saci"

class CreatePaginationItems < Saci::Record::Migration
  def change
    create_table :pagination_items do |t|
      t.string :title, null: false
      t.boolean :published, default: false
      t.timestamps
    end
  end
end

class PaginateItem < Saci::Record::Base
  table "pagination_items"

  column id : Int64, primary: true
  column title : String
  column published : Bool, default: false
  timestamps
end

PAGINATION_DB_PATH = "/tmp/opencode/saci_pagination_test.db"

def seed_paginate_items(n : Int32, published : Bool = true) : Nil
  n.times do |i|
    PaginateItem.create!(title: "item-%03d" % i, published: published)
  end
end

class PaginationDemoController < Saci::Controller
  def index
    page_num = params.int("page", 1) || 1
    per = params.int("per_page", 5) || 5
    page = Saci::Pagination.paginate(
      PaginateItem.where(published: true).order(:id),
      page: page_num,
      per_page: per
    )
    render html: page.records.map { |r| r.title.to_s }.join(",") +
      Saci::Pagination.paginate_nav(page, "/items")
  end
end

def pagination_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/items", PaginationDemoController, :index
  end
end

describe "Saci::Pagination.paginate" do
  before_all do
    File.delete(PAGINATION_DB_PATH) if File.exists?(PAGINATION_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{PAGINATION_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreatePaginationItems] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "divides exact counts into full pages" do
    seed_paginate_items(50)
    first = Saci::Pagination.paginate(PaginateItem.all, page: 1, per_page: 25)
    first.total_count.should eq(50_i64)
    first.total_pages.should eq(2)
    first.current_page.should eq(1)
    first.per_page.should eq(25)
    first.records.size.should eq(25)
    first.next_page.should eq(2)
    first.prev_page.should be_nil

    second = Saci::Pagination.paginate(PaginateItem.all, page: 2, per_page: 25)
    second.records.size.should eq(25)
    second.next_page.should be_nil
    second.prev_page.should eq(1)
  end

  it "puts the remainder on the last page" do
    seed_paginate_items(53)
    page = Saci::Pagination.paginate(PaginateItem.all, page: 3, per_page: 25)
    page.total_count.should eq(53_i64)
    page.total_pages.should eq(3)
    page.records.size.should eq(3)
    page.next_page.should be_nil
    page.prev_page.should eq(2)
  end

  it "handles an empty result set" do
    page = Saci::Pagination.paginate(PaginateItem.all, page: 1, per_page: 25)
    page.total_count.should eq(0_i64)
    page.total_pages.should eq(0)
    page.current_page.should eq(1)
    page.records.should be_empty
    page.next_page.should be_nil
    page.prev_page.should be_nil
  end

  it "preserves ordering across pages" do
    seed_paginate_items(30)
    page = Saci::Pagination.paginate(PaginateItem.order(title: :desc), page: 1, per_page: 10)
    page.records.map { |r| r.title.to_s }.should eq((20...30).to_a.reverse.map { |i| "item-%03d" % i })
    second = Saci::Pagination.paginate(PaginateItem.order(title: :desc), page: 2, per_page: 10)
    second.records.map { |r| r.title.to_s }.should eq((10...20).to_a.reverse.map { |i| "item-%03d" % i })
  end

  it "preserves filters" do
    seed_paginate_items(10, published: true)
    seed_paginate_items(5, published: false)
    page = Saci::Pagination.paginate(PaginateItem.where(published: true), page: 1, per_page: 25)
    page.total_count.should eq(10_i64)
    page.records.all? { |r| r.published == true }.should be_true
  end

  it "clamps page 0 and negative pages to the first page" do
    seed_paginate_items(30)
    Saci::Pagination.paginate(PaginateItem.all, page: 0, per_page: 10).current_page.should eq(1)
    Saci::Pagination.paginate(PaginateItem.all, page: -7, per_page: 10).current_page.should eq(1)
  end

  it "clamps out-of-range pages to the last page (pinned)" do
    seed_paginate_items(53)
    page = Saci::Pagination.paginate(PaginateItem.all, page: 9999, per_page: 25)
    page.current_page.should eq(3)
    page.records.size.should eq(3)
    page.next_page.should be_nil
    page.prev_page.should eq(2)
  end

  it "caps per_page at 100 (pinned)" do
    seed_paginate_items(5)
    page = Saci::Pagination.paginate(PaginateItem.all, page: 1, per_page: 1000)
    page.per_page.should eq(100)
    page.records.size.should eq(5)
  end

  it "falls back to the default per_page for zero/negative values (pinned)" do
    seed_paginate_items(5)
    Saci::Pagination.paginate(PaginateItem.all, page: 1, per_page: 0).per_page.should eq(25)
    Saci::Pagination.paginate(PaginateItem.all, page: 1, per_page: -3).per_page.should eq(25)
  end
end

describe "Saci::Pagination.paginate_nav" do
  it "renders nothing for a single page or an empty set" do
    single = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 5_i64, 1_i32, 1_i32, 25_i32, nil, nil)
    Saci::Pagination.paginate_nav(single, "/items").should eq("")
    empty = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 0_i64, 0_i32, 1_i32, 25_i32, nil, nil)
    Saci::Pagination.paginate_nav(empty, "/items").should eq("")
  end

  it "links pages with a current marker and prev/next" do
    page = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 125_i64, 5_i32, 2_i32, 25_i32, 3, 1)
    out = Saci::Pagination.paginate_nav(page, "/items")
    out.should contain(%(<nav class="pagination">))
    out.should contain(%(href="/items"))
    out.should contain(%(href="/items/page/3"))
    out.should contain(%(<span class="current" aria-current="page">2</span>))
    out.should contain(%(rel="prev"))
    out.should contain(%(rel="next"))
  end

  it "windows numbers with ellipsis on many pages" do
    page = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 250_i64, 10_i32, 5_i32, 25_i32, 6, 4)
    out = Saci::Pagination.paginate_nav(page, "/items")
    out.should contain(%(href="/items"))
    out.should contain(%(href="/items/page/10"))
    out.should contain(%(<span class="current" aria-current="page">5</span>))
    out.scan(%(<span class="gap">…</span>)).size.should eq(2)
    out.should_not contain(%(>2<))
    out.should_not contain(%(>8<))
  end

  it "omits prev on the first page and next on the last page" do
    first = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 50_i64, 2_i32, 1_i32, 25_i32, 2, nil)
    out = Saci::Pagination.paginate_nav(first, "/items")
    out.should_not contain(%(rel="prev"))
    out.should contain(%(rel="next"))
    last = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 50_i64, 2_i32, 2_i32, 25_i32, nil, 1)
    out = Saci::Pagination.paginate_nav(last, "/items")
    out.should contain(%(rel="prev"))
    out.should_not contain(%(rel="next"))
  end

  it "honors :page placeholders and query-string bases" do
    page = Saci::Pagination::Page(PaginateItem).new([] of PaginateItem, 75_i64, 3_i32, 2_i32, 25_i32, 3, 1)
    Saci::Pagination.paginate_nav(page, "/active/page/:page").should contain(%(href="/active/page/1"))
    Saci::Pagination.paginate_nav(page, "/items?tag=x").should contain(%(href="/items?tag=x&amp;page=1"))
  end
end

describe "pagination integration" do
  before_all do
    File.delete(PAGINATION_DB_PATH) if File.exists?(PAGINATION_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{PAGINATION_DB_PATH}")
    Saci::Record::Migrator.migrate(
      Saci::Record::Base.connection.as(DB::Database),
      [CreatePaginationItems] of Saci::Record::Migration.class
    )
  end

  after_all do
    Saci::Record::Base.connection.as(DB::Database).close
  end

  before_each do
    Saci::Record.clean_database!
  end

  it "paginates a real model through TestSession get" do
    seed_paginate_items(12)
    Saci::TestSession.serve(pagination_router) do |app|
      resp = app.get("/items?page=2&per_page=5")
      resp.status_code.should eq(200)
      resp.body.should contain("item-005")
      resp.body.should contain("item-009")
      resp.body.should_not contain("item-000,")
      resp.body.should contain(%(<span class="current" aria-current="page">2</span>))
      resp.body.should contain(%(rel="prev"))
      resp.body.should contain(%(rel="next"))
    end
  end

  it "falls back gracefully for non-numeric page params via params.int" do
    seed_paginate_items(12)
    Saci::TestSession.serve(pagination_router) do |app|
      resp = app.get("/items?page=abc&per_page=xyz")
      resp.status_code.should eq(200)
      resp.body.should contain("item-000")
      resp.body.should contain(%(<span class="current" aria-current="page">1</span>))
    end
  end
end
