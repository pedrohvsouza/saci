require "spec"
require "../src/saci"

class SaciMetricsDemoController < Saci::Controller
  def index
    render text: "ok"
  end
end

def saci_metrics_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/hello", SaciMetricsDemoController, :index
    r.get "/metrics", Saci::Metrics::Controller, :index
  end
end

describe Saci::Metrics do
  before_each do
    Saci::Metrics.reset!
  end

  after_each do
    Saci::Metrics.reset!
    Saci::Job.reset_error_handler!
  end

  it "counts requests, statuses, routes and durations" do
    Saci::Metrics.track_request("Posts#index", 200, 10.0)
    Saci::Metrics.track_request("Posts#index", 200, 30.0)
    Saci::Metrics.track_request("Posts#show", 404, 5.0)

    Saci::Metrics.requests_total.should eq(3)
    Saci::Metrics.status_counts.should eq({200 => 2_i64, 404 => 1_i64})
    Saci::Metrics.route_counts.should eq({"Posts#index" => 2_i64, "Posts#show" => 1_i64})
    Saci::Metrics.route_avg_ms("Posts#index").not_nil!.should be_close(20.0, 0.001)
    Saci::Metrics.route_avg_ms("Posts#show").not_nil!.should be_close(5.0, 0.001)
    Saci::Metrics.route_avg_ms("Missing#x").should be_nil
  end

  it "counts jobs and cache hooks" do
    Saci::Metrics.job_ok!
    Saci::Metrics.job_ok!
    Saci::Metrics.job_failed!
    Saci::Metrics.cache_hit!
    Saci::Metrics.cache_miss!
    Saci::Metrics.cache_miss!

    Saci::Metrics.jobs_ok.should eq(2)
    Saci::Metrics.jobs_failed.should eq(1)
    Saci::Metrics.cache_hits.should eq(1)
    Saci::Metrics.cache_misses.should eq(2)
  end

  it "wires jobs through the decoupled on_error hook" do
    Saci::Job.on_error { |_, _| Saci::Metrics.job_failed! }
    Saci::Job.report_error("DemoJob", Exception.new("boom"))
    Saci::Metrics.jobs_failed.should eq(1)
  end

  it "is a no-op when disabled" do
    Saci::Metrics.enabled = false
    Saci::Metrics.track_request("Posts#index", 200, 1.0)
    Saci::Metrics.job_ok!
    Saci::Metrics.job_failed!
    Saci::Metrics.cache_hit!
    Saci::Metrics.cache_miss!
    Saci::Metrics.requests_total.should eq(0)
    Saci::Metrics.jobs_ok.should eq(0)
    Saci::Metrics.jobs_failed.should eq(0)
    Saci::Metrics.cache_hits.should eq(0)
    Saci::Metrics.cache_misses.should eq(0)
  ensure
    Saci::Metrics.enabled = true
  end

  it "resets to a blank slate" do
    Saci::Metrics.track_request("Posts#index", 200, 1.0)
    Saci::Metrics.job_failed!
    Saci::Metrics.enabled = false
    Saci::Metrics.reset!
    Saci::Metrics.enabled.should be_true
    Saci::Metrics.requests_total.should eq(0)
    Saci::Metrics.status_counts.should be_empty
    Saci::Metrics.route_counts.should be_empty
    Saci::Metrics.jobs_failed.should eq(0)
  end

  it "renders the JSON snapshot shape" do
    Saci::Metrics.track_request("Posts#index", 200, 10.0)
    Saci::Metrics.job_ok!
    Saci::Metrics.cache_hit!

    body = JSON.parse(Saci::Metrics.snapshot_json)
    body["enabled"].as_bool.should be_true
    body["requests"]["total"].as_i64.should eq(1)
    body["requests"]["by_status"]["200"].as_i64.should eq(1)
    body["requests"]["routes"]["Posts#index"]["count"].as_i64.should eq(1)
    body["requests"]["routes"]["Posts#index"]["avg_ms"].as_f.should be_close(10.0, 0.001)
    body["jobs"]["ok"].as_i64.should eq(1)
    body["jobs"]["failed"].as_i64.should eq(0)
    body["cache"]["hits"].as_i64.should eq(1)
    body["cache"]["misses"].as_i64.should eq(0)
    # DB gauges are best-effort — present, int or null, never raising.
    ["pending", "dead"].each do |key|
      v = body["jobs"][key]
      (v.as_i64? || v.raw.nil?).should be_true
    end
    size = body["db"]["size_bytes"]
    (size.as_i64? || size.raw.nil?).should be_true
  end

  it "renders Prometheus exposition" do
    Saci::Metrics.track_request("Posts#index", 200, 10.0)
    Saci::Metrics.job_failed!
    Saci::Metrics.cache_miss!

    prom = Saci::Metrics.to_prometheus
    prom.should contain("saci_requests_total 1")
    prom.should contain(%(saci_requests_by_status_total{status="200"} 1))
    prom.should contain(%(saci_route_requests_total{route="Posts#index"} 1))
    prom.should contain(%(saci_request_duration_ms_sum{route="Posts#index"} 10.0))
    prom.should contain("saci_jobs_failed_total 1")
    prom.should contain("saci_cache_misses_total 1")
    prom.should contain("saci_cache_hits_total 0")
    prom.should contain("saci_db_size_bytes")
  end

  it "mounts the endpoint returning JSON by default" do
    Saci::Metrics.track_request("SaciMetricsDemo#index", 200, 4.0)
    Saci::TestSession.serve(saci_metrics_router) do |app|
      resp = app.get("/metrics")
      resp.status_code.should eq(200)
      resp.headers["Content-Type"].should contain("application/json")
      JSON.parse(resp.body)["requests"]["total"].as_i64.should eq(1)
    end
  end

  it "serves Prometheus text on Accept or ?format=prom" do
    Saci::TestSession.serve(saci_metrics_router) do |app|
      plain = app.get("/metrics", HTTP::Headers{"Accept" => "text/plain"})
      plain.status_code.should eq(200)
      plain.headers["Content-Type"].should contain("text/plain")
      plain.body.should contain("saci_requests_total")

      prom = app.get("/metrics?format=prom")
      prom.status_code.should eq(200)
      prom.body.should contain("saci_requests_total")
    end
  end

  it "db_info never raises without a database" do
    info = Saci::Metrics.db_info
    info.is_a?(NamedTuple(pending: Int64?, dead: Int64?, size_bytes: Int64?)).should be_true
  end
end
