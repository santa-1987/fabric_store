attributes *variant_attributes
cache [I18n.locale, 'small_variant', root_object]

node(:display_price) { |p| p.display_price.to_s }
node(:options_text) { |v| v.options_text }
node(:in_stock) { |v| v.in_stock? }

child :option_values => :option_values do
  attributes *option_value_attributes
end

child(:images => :images) { extends "spree/api/images/show" }
