require "../src/saci"

# Run with: crystal run examples/i18n_example.cr
Saci::I18n.load_path.replace(["examples/locales/*.yml"])
Saci::I18n.reload!

puts "available: #{Saci::I18n.available_locales.inspect}"
puts Saci::I18n.t("hello")
puts Saci::I18n.t("greeting", name: "Ada")
puts Saci::I18n.t("items", count: 0)
puts Saci::I18n.t("items", count: 1)
puts Saci::I18n.t("items", count: 5)

Saci::I18n.with_locale(:es) do
  puts Saci::I18n.t("hello")
  puts Saci::I18n.t("items", count: 2)
end

puts Saci::I18n.t("hello", locale: :es)
puts Saci::I18n.t("missing.key")
puts "header fr -> #{Saci::I18n.locale_from_header("fr-FR,es;q=0.8")}"
puts "header es -> #{Saci::I18n.locale_from_header("es-MX,es;q=0.9")}"
