require "../src/saci"

# Demo: jobs (inline/retry/test adapters) + mailers (test + file delivery).
# Run with: crystal run examples/jobs_mailers_example.cr

class DemoReportJob < Saci::Job::Base
  queue_as :reports
  retry_on IO::Error, attempts: 3

  @@done = [] of String
  @@mutex = Mutex.new

  def self.done : Array(String)
    @@mutex.synchronize { @@done.dup }
  end

  def perform(payload : JSON::Any) : Nil
    @@mutex.synchronize { @@done << "report-#{payload["id"]}" }
  end
end

class DemoMailer < Saci::Mailer::Base
  default_from "demo@saci.example"

  def self.hello(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Hello from Saci!") do |format|
      format.text { "Hello, #{email}!" }
      format.html { "<h1>Hello, #{email}!</h1>" }
    end
  end
end

Saci::Job.with_adapter(:inline) do
  DemoReportJob.perform_later({id: 7})
  DemoReportJob.set(wait: 0.seconds).perform_later({id: 8})
end
puts "jobs done: #{DemoReportJob.done.inspect}"

Saci::Job.queue_adapter = :test
Saci::Job.clear_enqueued!
DemoReportJob.perform_later({id: 9})
puts "enqueued: #{Saci::Job.enqueued_jobs.map { |j| j[:job] }.inspect}"

Saci::Mailer.delivery_adapter = :test
Saci::Mailer.clear_deliveries!
DemoMailer.hello("ada@example.com").deliver_now
puts "test mailbox: #{Saci::Mailer.deliveries.map(&.subject).inspect}"

Saci::Mailer.delivery_adapter = :file
Saci::Mailer.file_path = "tmp/demo-mails"
DemoMailer.hello("grace@example.com").deliver_now
puts "file mailbox: #{Dir.glob("tmp/demo-mails/*.eml").size} message(s)"

Saci::Job.with_adapter(:inline) do
  DemoMailer.hello("alan@example.com").deliver_later
end
puts "after deliver_later: #{Saci::Mailer.deliveries.size} in test box"
