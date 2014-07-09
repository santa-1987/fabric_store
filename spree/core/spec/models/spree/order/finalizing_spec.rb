require 'spec_helper'

describe Spree::Order do
  let(:order) { stub_model("Spree::Order") }

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

    context "order is not considered risky" do
      before do
        order.stub :is_risky? => false
      end

      it "should set completed_at" do
        order.finalize!
        expect(order.completed_at).to be_present
      end
    end
  end
end