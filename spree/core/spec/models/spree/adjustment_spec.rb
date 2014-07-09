# encoding: utf-8
#

require 'spec_helper'

describe Spree::Adjustment do

  let(:order) { mock_model(Spree::Order, update!: nil) }
  let(:adjustment) { Spree::Adjustment.create(:label => "Adjustment", :amount => 5) }

  context "adjustment state" do
    let(:adjustment) { create(:adjustment, state: 'open') }

    context "#closed?" do
      it "is true when adjustment state is closed" do
        adjustment.state = "closed"
        adjustment.should be_closed
      end

      it "is false when adjustment state is open" do
        adjustment.state = "open"
        adjustment.should_not be_closed
      end
    end
  end

  context '#currency' do
    it 'returns the globally configured currency' do
      adjustment.currency.should == 'USD'
    end
  end

  context "#display_amount" do
    before { adjustment.amount = 10.55 }

    context "with display_currency set to true" do
      before { Spree::Config[:display_currency] = true }

      it "shows the currency" do
        adjustment.display_amount.to_s.should == "$10.55 USD"
      end
    end

    context "with display_currency set to false" do
      before { Spree::Config[:display_currency] = false }

      it "does not include the currency" do
        adjustment.display_amount.to_s.should == "$10.55"
      end
    end

    context "with currency set to JPY" do
      context "when adjustable is set to an order" do
        before do
          order.stub(:currency) { 'JPY' }
          adjustment.adjustable = order
        end

        it "displays in JPY" do
          adjustment.display_amount.to_s.should == "¥11"
        end
      end

      context "when adjustable is nil" do
        it "displays in the default currency" do
          adjustment.display_amount.to_s.should == "$10.55"
        end
      end
    end
  end

  context '#update!' do
    context "when adjustment is closed" do
      before { adjustment.stub :closed? => true }

      it "does not update the adjustment" do
        adjustment.should_not_receive(:update_column)
        adjustment.update!
      end
    end

    context "when adjustment is open" do
      before { adjustment.stub :closed? => false }

      it "updates the amount" do
        adjustment.stub :adjustable => double("Adjustable")
        adjustment.stub :source => double("Source")
        adjustment.source.should_receive("compute_amount").with(adjustment.adjustable).and_return(5)
        adjustment.should_receive(:update_columns).with(amount: 5, updated_at: kind_of(Time))
        adjustment.update!
      end
    end
  end

end
