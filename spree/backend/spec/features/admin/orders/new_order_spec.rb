require 'spec_helper'

describe "New Order" do
  let!(:stock_location) { create(:stock_location_with_items) }
  let!(:product) { create(:product) }
  let!(:state) { create(:state) }
  let!(:user) { create(:user) }
  let!(:payment_method) { create(:check_payment_method) }
  let!(:shipping_method) { create(:shipping_method) }
  let!(:stock_item) { product.master.stock_items.first.adjust_count_on_hand(10) }

  stub_authorization!

  before do
    visit spree.admin_path
    click_on "Orders"
    click_on "New Order"
  end

  it "completes new order succesfully", js: true do
    select2_search product.name, :from => Spree.t(:name_or_sku)
    click_icon :plus
    click_on "Customer Details"

    within "#select-customer" do
      targetted_select2_search user.email, :from => "#s2id_customer_search"
    end

    check "order_use_billing"
    fill_in_address
    click_on "Update"

    click_on "Payments"
    click_on "Update"

    expect(current_path).to eql(spree.admin_order_payments_path(Spree::Order.last))
    click_icon "capture"

    click_on "Order Details"
    click_on "ship"
    wait_for_ajax

    page.should have_content("shipped")
  end

  context "adding new item to the order", js: true do
    it "inventory items show up just fine" do
      select2_search product.name, :from => Spree.t(:name_or_sku)

      within("table.stock-levels") do
        fill_in "stock_item_quantity", :with => 2
        click_icon :plus
      end

      within(".stock-contents") do
        page.should have_content(product.name)
      end
    end
  end

  # Regression test for #3958
  context "without a delivery step", js: true do
    before do
      Spree::Order.stub :checkout_step_names => [:address, :payment, :confirm, :complete]
    end

    it "can still see line items" do
      select2_search product.name, :from => Spree.t(:name_or_sku)
      click_icon :plus
      within(".line-items") do
        within(".line-item-name") do
          page.should have_content(product.name)
        end
        within(".line-item-qty-show") do
          page.should have_content("1")
        end
        within(".line-item-price") do
          page.should have_content(product.price)
        end
      end
    end
  end

  # Regression test for #3336
  context "start by customer address" do
    it "completes order fine", js: true do
      click_on "Customer Details"

      within "#select-customer" do
        targetted_select2_search user.email, :from => "#s2id_customer_search"
      end

      check "order_use_billing"
      fill_in_address
      click_on "Update"

      click_on "Order Details"
      select2_search product.name, :from => Spree.t(:name_or_sku)
      click_icon :plus
      wait_for_ajax

      click_on "Payments"
      click_on "Continue"

      within(".additional-info .state") do
        page.should have_content("COMPLETE")
      end
    end
  end

  def fill_in_address(kind = "bill")
    fill_in "First Name",              :with => "John 99"
    fill_in "Last Name",               :with => "Doe"
    fill_in "Street Address",          :with => "100 first lane"
    fill_in "Street Address (cont'd)", :with => "#101"
    fill_in "City",                    :with => "Bethesda"
    fill_in "Zip",                     :with => "20170"
    targetted_select2_search state.name, :from => "#s2id_order_#{kind}_address_attributes_state_id"
    fill_in "Phone",                   :with => "123-456-7890"
  end
end
