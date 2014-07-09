require 'spec_helper'

module Spree
  module PromotionHandler
    describe Cart do
      let(:line_item) { create(:line_item) }
      let(:order) { line_item.order }

      let(:promotion) { Promotion.create(name: "At line items") }
      let(:calculator) { Calculator::FlatPercentItemTotal.new(preferred_flat_percent: 10) }

      subject { Cart.new(order, line_item) }

      context "activates in LineItem level" do
        let!(:action) { Promotion::Actions::CreateItemAdjustments.create(promotion: promotion, calculator: calculator) }
        let(:adjustable) { line_item }

        shared_context "creates the adjustment" do
          it "creates the adjustment" do
            expect {
              subject.activate
            }.to change { adjustable.adjustments.count }.by(1)
          end
        end

        context "promotion with no rules" do
          include_context "creates the adjustment"
        end

        context "promotion includes item involved" do
          let!(:rule) { Promotion::Rules::Product.create(products: [line_item.product], promotion: promotion) }

          include_context "creates the adjustment"
        end

        context "promotion has item total rule" do
          let(:shirt) { create(:product) }
          let!(:rule) { Promotion::Rules::ItemTotal.create(preferred_operator: 'gt', preferred_amount: 50, promotion: promotion) }

          before do
            # Makes the order eligible for this promotion
            order.item_total = 100
            order.save
          end

          include_context "creates the adjustment"
        end
      end

      context "activates in Order level" do
        let!(:action) { Promotion::Actions::CreateAdjustment.create(promotion: promotion, calculator: calculator) }
        let(:adjustable) { order }

        shared_context "creates the adjustment" do
          it "creates the adjustment" do
            expect {
              subject.activate
            }.to change { adjustable.adjustments.count }.by(1)
          end
        end

        context "promotion with no rules" do
          before do
            # Gives the calculator something to discount
            order.item_total = 10
            order.save
          end

          include_context "creates the adjustment"
        end

        context "promotion has item total rule" do
          let(:shirt) { create(:product) }
          let!(:rule) { Promotion::Rules::ItemTotal.create(preferred_operator: 'gt', preferred_amount: 50, promotion: promotion) }

          before do
            # Makes the order eligible for this promotion
            order.item_total = 100
            order.save
          end

          include_context "creates the adjustment"
        end
      end
    end
  end
end
