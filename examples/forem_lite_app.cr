# Forem Lite demo server — run with:
#   crystal run examples/forem_lite_app.cr
# Then visit http://127.0.0.1:3000/ (HTML feed) or try the JSON API:
#   curl http://127.0.0.1:3000/lite_health
#   curl -X POST http://127.0.0.1:3000/lite_users \
#     -H 'Content-Type: application/json' \
#     -d '{"username":"ada","email":"ada@example.com","password":"secret123"}'
require "./forem_lite_domain"

ENV["SECRET_KEY_BASE"] ||= "forem-lite-dev-secret"

["./tmp/forem_lite.db", "./tmp/forem_lite_analytics.db"].each do |path|
  File.delete(path) if File.exists?(path)
end

ForemLite.setup("./tmp/forem_lite.db", "./tmp/forem_lite_analytics.db", "./tmp/forem_lite_storage")
Saci::Mailer.delivery_adapter = :file
Saci::Mailer.file_path = "tmp/forem_lite_mails"
ForemLite.seed_demo!

router = forem_lite_router
puts "routes:"
router.routes_table.each { |line| puts "  #{line}" }
router.ws_routes_table.each { |line| puts "  #{line}" }

Saci::Application.new(router).listen(3000)
