require "../src/saci"

# Demo: jobs (inline/retry/test adapters) + mailers (test + file delivery).
# Run with: crystal run examples/jobs_mailers_example.cr

class DemoReportJob < Job::Base
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

class DemoMailer < Mailer::Base
  default_from "demo@saci.example"

  def self.hello(email : String) : Mailer::Mail
    mail(to: email, subject: "Hello from Saci!") do |format|
      format.text { "Hello, #{email}!" }
      format.html { "<h1>Hello, #{email}!</h1>" }
    end
  end
end

Job.with_adapter(:inline) do
  DemoReportJob.perform_later({id: 7})
  DemoReportJob.set(wait: 0.seconds).perform_later({id: 8})
end
puts "jobs done: #{DemoReportJob.done.inspect}"

Job.queue_adapter = :test
Job.clear_enqueued!
DemoReportJob.perform_later({id: 9})
puts "enqueued: #{Job.enqueued_jobs.map { |j| j[:job] }.inspect}"

Mailer.delivery_adapter = :test
Mailer.clear_deliveries!
DemoMailer.hello("ada@example.com").deliver_now
puts "test mailbox: #{Mailer.deliveries.map(&.subject).inspect}"

Mailer.delivery_adapter = :file
Mailer.file_path = "tmp/demo-mails"
DemoMailer.hello("grace@example.com").deliver_now
puts "file mailbox: #{Dir.glob("tmp/demo-mails/*.eml").size} message(s)"

Job.with_adapter(:inline) do
  DemoMailer.hello("alan@example.com").deliver_later
end
puts "after deliver_later: #{Mailer.deliveries.size} in test box"
