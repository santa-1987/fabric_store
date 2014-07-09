# encoding: utf-8

require 'spec_helper'

class FakeCalculator < Spree::Calculator
  def compute(computable)
    5
  end
end

describe Spree::Order do
  let(:user) { stub_model(Spree::LegacyUser, :email => "spree@example.com") }
  let(:order) { stub_model(Spree::Order, :user => user) }

  before do
    Spree::LegacyUser.stub(:current => mock_model(Spree::LegacyUser, :id => 123))
  end

  context "#create" do
    let(:order) { Spree::Order.create }

    it "should assign an order number" do
      order.number.should_not be_nil
    end

    it 'should create a randomized 22 character token' do
      order.guest_token.size.should == 22
    end
  end

  context "creates shipments cost" do
    let(:shipment) { double }

    before { order.stub shipments: [shipment] }

    it "update and persist totals" do
      expect(shipment).to receive :update_amounts
      expect(order.updater).to receive :update_shipment_total
      expect(order.updater).to receive :persist_totals

      order.set_shipments_cost
    end
  end

  context "#finalize!" do
    let(:order) { Spree::Order.create(email: 'test@example.com') }

    before do
      order.update_column :state, 'complete'
    end

    it "should set completed_at" do
      order.should_receive(:touch).with(:completed_at)
      order.finalize!
    end

    it "should sell inventory units" do
      order.shipments.each do |shipment|
        shipment.should_receive(:update!)
        shipment.should_receive(:finalize!)
      end
      order.finalize!
    end

    it "should decrease the stock for each variant in the shipment" do
      order.shipments.each do |shipment|
        shipment.stock_location.should_receive(:decrease_stock_for_variant)
      end
      order.finalize!
    end

    it "should change the shipment state to ready if order is paid" do
      Spree::Shipment.create(order: order)
      order.shipments.reload

      order.stub(:paid? => true, :complete? => true)
      order.finalize!
      order.reload # reload so we're sure the changes are persisted
      order.shipment_state.should == 'ready'
    end

    after { Spree::Config.set :track_inventory_levels => true }
    it "should not sell inventory units if track_inventory_levels is false" do
      Spree::Config.set :track_inventory_levels => false
      Spree::InventoryUnit.should_not_receive(:sell_units)
      order.finalize!
    end

    it "should send an order confirmation email" do
      mail_message = double "Mail::Message"
      Spree::OrderMailer.should_receive(:confirm_email).with(order.id).and_return mail_message
      mail_message.should_receive :deliver
      order.finalize!
    end

    it "sets confirmation delivered when finalizing" do
      expect(order.confirmation_delivered?).to be_false
      order.finalize!
      expect(order.confirmation_delivered?).to be_true
    end

    it "should not send duplicate confirmation emails" do
      order.stub(:confirmation_delivered? => true)
      Spree::OrderMailer.should_not_receive(:confirm_email)
      order.finalize!
    end

    it "should freeze all adjustments" do
      # Stub this method as it's called due to a callback
      # and it's irrelevant to this test
      order.stub :has_available_shipment
      Spree::OrderMailer.stub_chain :confirm_email, :deliver
      adjustments = [double]
      order.should_receive(:all_adjustments).and_return(adjustments)
      adjustments.each do |adj|
	      expect(adj).to receive(:close)
      end
      order.finalize!
    end

    context "order is considered risky" do
      before do
        order.stub :is_risky? => true
      end

      it "should change state to risky" do
        expect(order).to receive(:considered_risky!)
        order.finalize!
      end

      context "and order is approved" do
        before do
          order.stub :approved? => true
        end

        it "should leave order in complete state" do
          order.finalize!
          expect(order.state).to eq 'complete'
        end
      end
    end
  end

  context "insufficient_stock_lines" do
    let(:line_item) { mock_model Spree::LineItem, :insufficient_stock? => true }

    before { order.stub(:line_items => [line_item]) }

    it "should return line_item that has insufficient stock on hand" do
      order.insufficient_stock_lines.size.should == 1
      order.insufficient_stock_lines.include?(line_item).should be_true
    end
  end

  context "empty!" do
    let(:order) { stub_model(Spree::Order, item_count: 2) }

    before do
      order.stub(:line_items => line_items = [1, 2])
      order.stub(:adjustments => adjustments = [])
    end

    it "clears out line items, adjustments and update totals" do
      expect(order.line_items).to receive(:destroy_all)
      expect(order.adjustments).to receive(:destroy_all)
      expect(order.shipments).to receive(:destroy_all)
      expect(order.updater).to receive(:update_totals)
      expect(order.updater).to receive(:persist_totals)

      order.empty!
      expect(order.item_total).to eq 0
    end
  end

  context "#display_outstanding_balance" do
    it "returns the value as a spree money" do
      order.stub(:outstanding_balance) { 10.55 }
      order.display_outstanding_balance.should == Spree::Money.new(10.55)
    end
  end

  context "#display_item_total" do
    it "returns the value as a spree money" do
      order.stub(:item_total) { 10.55 }
      order.display_item_total.should == Spree::Money.new(10.55)
    end
  end

  context "#display_adjustment_total" do
    it "returns the value as a spree money" do
      order.adjustment_total = 10.55
      order.display_adjustment_total.should == Spree::Money.new(10.55)
    end
  end

  context "#display_total" do
    it "returns the value as a spree money" do
      order.total = 10.55
      order.display_total.should == Spree::Money.new(10.55)
    end
  end

  context "#currency" do
    context "when object currency is ABC" do
      before { order.currency = "ABC" }

      it "returns the currency from the object" do
        order.currency.should == "ABC"
      end
    end

    context "when object currency is nil" do
      before { order.currency = nil }

      it "returns the globally configured currency" do
        order.currency.should == "USD"
      end
    end
  end

  # Regression tests for #2179
  context "#merge!" do
    let(:variant) { create(:variant) }
    let(:order_1) { Spree::Order.create }
    let(:order_2) { Spree::Order.create }

    it "destroys the other order" do
      order_1.merge!(order_2)
      lambda { order_2.reload }.should raise_error(ActiveRecord::RecordNotFound)
    end

    context "user is provided" do
      it "assigns user to new order" do
        order_1.merge!(order_2, user)
        expect(order_1.user).to eq user
      end
    end

    context "merging together two orders with line items for the same variant" do
      before do
        order_1.contents.add(variant, 1)
        order_2.contents.add(variant, 1)
      end

      specify do
        order_1.merge!(order_2)
        order_1.line_items.count.should == 1

        line_item = order_1.line_items.first
        line_item.quantity.should == 2
        line_item.variant_id.should == variant.id
      end
    end

    context "merging together two orders with different line items" do
      let(:variant_2) { create(:variant) }

      before do
        order_1.contents.add(variant, 1)
        order_2.contents.add(variant_2, 1)
      end

      specify do
        order_1.merge!(order_2)
        line_items = order_1.line_items
        line_items.count.should == 2

        expect(order_1.item_count).to eq 2
        expect(order_1.item_total).to eq line_items.map(&:amount).sum

        # No guarantee on ordering of line items, so we do this:
        line_items.pluck(:quantity).should =~ [1, 1]
        line_items.pluck(:variant_id).should =~ [variant.id, variant_2.id]
      end
    end
  end

  context "#confirmation_required?" do

    # Regression test for #4117
    it "is required if the state is currently 'confirm'" do
      order = Spree::Order.new
      assert !order.confirmation_required?
      order.state = 'confirm'
      assert order.confirmation_required?
    end

    context 'Spree::Config[:always_include_confirm_step] == true' do

      before do
        Spree::Config[:always_include_confirm_step] = true
      end

      it "returns true if payments empty" do
        order = Spree::Order.new
        assert order.confirmation_required?
      end
    end

    context 'Spree::Config[:always_include_confirm_step] == false' do

      it "returns false if payments empty and Spree::Config[:always_include_confirm_step] == false" do
        order = Spree::Order.new
        assert !order.confirmation_required?
      end

      it "does not bomb out when an order has an unpersisted payment" do
        order = Spree::Order.new
        order.payments.build
        assert !order.confirmation_required?
      end
    end
  end


  context "add_update_hook" do
    before do
      Spree::Order.class_eval do
        register_update_hook :add_awesome_sauce
      end
    end

    after do
      Spree::Order.update_hooks = Set.new
    end

    it "calls hook during update" do
      order = create(:order)
      order.should_receive(:add_awesome_sauce)
      order.update!
    end

    it "calls hook during finalize" do
      order = create(:order)
      order.should_receive(:add_awesome_sauce)
      order.finalize!
    end
  end

  describe "#tax_address" do
    before { Spree::Config[:tax_using_ship_address] = tax_using_ship_address }
    subject { order.tax_address }

    context "when tax_using_ship_address is true" do
      let(:tax_using_ship_address) { true }

      it 'returns ship_address' do
        subject.should == order.ship_address
      end
    end

    context "when tax_using_ship_address is not true" do
      let(:tax_using_ship_address) { false }

      it "returns bill_address" do
        subject.should == order.bill_address
      end
    end
  end

  describe "#restart_checkout_flow" do
    it "updates the state column to the first checkout_steps value" do
      order = create(:order, :state => "delivery")
      expect(order.checkout_steps).to eql ["address", "delivery", "complete"]
      expect{ order.restart_checkout_flow }.to change{order.state}.from("delivery").to("address")
    end

    context "with custom checkout_steps" do
      it "updates the state column to the first checkout_steps value" do
        order = create(:order, :state => "delivery")
        order.should_receive(:checkout_steps).and_return ["custom_step", "address", "delivery", "complete"]
        expect{ order.restart_checkout_flow }.to change{order.state}.from("delivery").to("custom_step")
      end
    end
  end

  # Regression tests for #4072
  context "#state_changed" do
    let(:order) { FactoryGirl.create(:order) }

    it "logs state changes" do
      order.update_column(:payment_state, 'balance_due')
      order.payment_state = 'paid'
      expect(order.state_changes).to be_empty
      order.state_changed('payment')
      state_change = order.state_changes.find_by(:name => 'payment')
      expect(state_change.previous_state).to eq('balance_due')
      expect(state_change.next_state).to eq('paid')
    end

    it "does not do anything if state does not change" do
      order.update_column(:payment_state, 'balance_due')
      expect(order.state_changes).to be_empty
      order.state_changed('payment')
      expect(order.state_changes).to be_empty
    end
  end

  # Regression test for #4199
  context "#available_payment_methods" do
    it "includes frontend payment methods" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "front_end",
        :environment => Rails.env
      })
      expect(order.available_payment_methods).to include(payment_method)
    end

    it "includes 'both' payment methods" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "both",
        :environment => Rails.env
      })
      expect(order.available_payment_methods).to include(payment_method)
    end

    it "does not include a payment method twice if display_on is blank" do
      payment_method = Spree::PaymentMethod.create!({
        :name => "Fake",
        :active => true,
        :display_on => "both",
        :environment => Rails.env
      })
      expect(order.available_payment_methods.count).to eq(1)
      expect(order.available_payment_methods).to include(payment_method)
    end
  end

  context "#apply_free_shipping_promotions" do
    it "calls out to the FreeShipping promotion handler" do
      shipment = double('Shipment')
      order.stub :shipments => [shipment]
      Spree::PromotionHandler::FreeShipping.should_receive(:new).and_return(handler = double)
      handler.should_receive(:activate)

      Spree::ItemAdjustments.should_receive(:new).with(shipment).and_return(adjuster = double)
      adjuster.should_receive(:update)

      order.updater.should_receive(:update_shipment_total)
      order.updater.should_receive(:persist_totals)
      order.apply_free_shipping_promotions
    end
  end


  context "#products" do
    before :each do
      @variant1 = mock_model(Spree::Variant, :product => "product1")
      @variant2 = mock_model(Spree::Variant, :product => "product2")
      @line_items = [mock_model(Spree::LineItem, :product => "product1", :variant => @variant1, :variant_id => @variant1.id, :quantity => 1),
                     mock_model(Spree::LineItem, :product => "product2", :variant => @variant2, :variant_id => @variant2.id, :quantity => 2)]
      order.stub(:line_items => @line_items)
    end

    it "contains?" do
      order.contains?(@variant1).should be_true
    end

    it "gets the quantity of a given variant" do
      order.quantity_of(@variant1).should == 1

      @variant3 = mock_model(Spree::Variant, :product => "product3")
      order.quantity_of(@variant3).should == 0
    end

    it "can find a line item matching a given variant" do
      order.find_line_item_by_variant(@variant1).should_not be_nil
      order.find_line_item_by_variant(mock_model(Spree::Variant)).should be_nil
    end
  end

  context "#generate_order_number" do
    it "should generate a random string" do
      order.generate_order_number.is_a?(String).should be_true
      (order.generate_order_number.to_s.length > 0).should be_true
    end
  end

  context "#associate_user!" do
    let!(:user) { FactoryGirl.create(:user) }

    it "should associate a user with a persisted order" do
      order = FactoryGirl.create(:order_with_line_items, created_by: nil)
      order.user = nil
      order.email = nil
      order.associate_user!(user)
      order.user.should == user
      order.email.should == user.email
      order.created_by.should == user

      # verify that the changes we made were persisted
      order.reload
      order.user.should == user
      order.email.should == user.email
      order.created_by.should == user
    end

    it "should not overwrite the created_by if it already is set" do
      creator = create(:user)
      order = FactoryGirl.create(:order_with_line_items, created_by: creator)

      order.user = nil
      order.email = nil
      order.associate_user!(user)
      order.user.should == user
      order.email.should == user.email
      order.created_by.should == creator

      # verify that the changes we made were persisted
      order.reload
      order.user.should == user
      order.email.should == user.email
      order.created_by.should == creator
    end

    it "should associate a user with a non-persisted order" do
      order = Spree::Order.new

      expect do
        order.associate_user!(user)
      end.to change { [order.user, order.email] }.from([nil, nil]).to([user, user.email])
    end

    it "should not persist an invalid address" do
      address = Spree::Address.new
      order.user = nil
      order.email = nil
      order.ship_address = address
      expect do
        order.associate_user!(user)
      end.not_to change { address.persisted? }.from(false)
    end
  end

  context "#can_ship?" do
    let(:order) { Spree::Order.create }

    it "should be true for order in the 'complete' state" do
      order.stub(:complete? => true)
      order.can_ship?.should be_true
    end

    it "should be true for order in the 'resumed' state" do
      order.stub(:resumed? => true)
      order.can_ship?.should be_true
    end

    it "should be true for an order in the 'awaiting return' state" do
      order.stub(:awaiting_return? => true)
      order.can_ship?.should be_true
    end

    it "should be true for an order in the 'returned' state" do
      order.stub(:returned? => true)
      order.can_ship?.should be_true
    end

    it "should be false if the order is neither in the 'complete' nor 'resumed' state" do
      order.stub(:resumed? => false, :complete? => false)
      order.can_ship?.should be_false
    end
  end

  context "#completed?" do
    it "should indicate if order is completed" do
      order.completed_at = nil
      order.completed?.should be_false

      order.completed_at = Time.now
      order.completed?.should be_true
    end
  end

  context "#allow_checkout?" do
    it "should be true if there are line_items in the order" do
      order.stub_chain(:line_items, :count => 1)
      order.checkout_allowed?.should be_true
    end
    it "should be false if there are no line_items in the order" do
      order.stub_chain(:line_items, :count => 0)
      order.checkout_allowed?.should be_false
    end
  end

  context "#amount" do
    before do
      @order = create(:order, :user => user)
      @order.line_items = [create(:line_item, :price => 1.0, :quantity => 2),
                           create(:line_item, :price => 1.0, :quantity => 1)]
    end
    it "should return the correct lum sum of items" do
      @order.amount.should == 3.0
    end
  end

  context "#backordered?" do
    it 'is backordered if one of the shipments is backordered' do
      order.stub(:shipments => [mock_model(Spree::Shipment, :backordered? => false),
                                mock_model(Spree::Shipment, :backordered? => true)])
      order.should be_backordered
    end
  end

  context "#can_cancel?" do
    it "should be false for completed order in the canceled state" do
      order.state = 'canceled'
      order.shipment_state = 'ready'
      order.completed_at = Time.now
      order.can_cancel?.should be_false
    end

    it "should be true for completed order with no shipment" do
      order.state = 'complete'
      order.shipment_state = nil
      order.completed_at = Time.now
      order.can_cancel?.should be_true
    end
  end

  context "#tax_total" do
    it "adds included tax and additional tax" do
      order.stub(:additional_tax_total => 10, :included_tax_total => 20)

      order.tax_total.should eq 30
    end
  end
end
