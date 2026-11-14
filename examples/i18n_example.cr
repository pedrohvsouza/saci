require "../src/saci"

# Run with: crystal run examples/i18n_example.cr
I18n.load_path.replace(["examples/locales/*.yml"])
I18n.reload!

puts "available: #{I18n.available_locales.inspect}"
puts I18n.t("hello")
puts I18n.t("greeting", name: "Ada")
puts I18n.t("items", count: 0)
puts I18n.t("items", count: 1)
puts I18n.t("items", count: 5)

I18n.with_locale(:es) do
  puts I18n.t("hello")
  puts I18n.t("items", count: 2)
end

puts I18n.t("hello", locale: :es)
puts I18n.t("missing.key")
puts "header fr -> #{I18n.locale_from_header("fr-FR,es;q=0.8")}"
puts "header es -> #{I18n.locale_from_header("es-MX,es;q=0.9")}"
