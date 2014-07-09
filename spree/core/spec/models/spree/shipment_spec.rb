require 'spec_helper'
require 'benchmark'

describe Spree::Shipment do
  let(:order) { mock_model Spree::Order, backordered?: false,
                                         canceled?: false,
                                         can_ship?: true,
                                         currency: 'USD',
                                         touch: true }
  let(:shipping_method) { create(:shipping_method, name: "UPS") }
  let(:shipment) do
    shipment = Spree::Shipment.new
    shipment.stub(shipping_method: shipping_method)
    shipment.stub(order: order)
    shipment.state = 'pending'
    shipment.cost = 1
    shipment.save
    shipment
  end

  let(:variant) { mock_model(Spree::Variant) }
  let(:line_item) { mock_model(Spree::LineItem, variant: variant) }

  # Regression test for #4063
  context "number generation" do
    before do
      order.stub :update!
    end

    it "generates a number containing a letter + 11 numbers" do
      shipment.save
      shipment.number[0].should == "H"
      /\d{11}/.match(shipment.number).should_not be_nil
      shipment.number.length.should == 12
    end
  end

  it 'is backordered if one if its inventory_units is backordered' do
    shipment.stub(inventory_units: [
      mock_model(Spree::InventoryUnit, backordered?: false),
      mock_model(Spree::InventoryUnit, backordered?: true)
    ])
    shipment.should be_backordered
  end

  context "display_amount" do
    it "retuns a Spree::Money" do
      shipment.stub(:cost) { 21.22 }
      shipment.display_amount.should == Spree::Money.new(21.22)
    end
  end

  context "display_final_price" do
    it "retuns a Spree::Money" do
      shipment.stub(:final_price) { 21.22 }
      shipment.display_final_price.should == Spree::Money.new(21.22)
    end
  end

  context "display_item_cost" do
    it "retuns a Spree::Money" do
      shipment.stub(:item_cost) { 21.22 }
      shipment.display_item_cost.should == Spree::Money.new(21.22)
    end
  end

  it "#item_cost" do
    shipment = create(:shipment, order: create(:order_with_totals))
    shipment.item_cost.should eql(10.0)
  end

  it "#discounted_cost" do
    shipment = create(:shipment)
    shipment.cost = 10
    shipment.promo_total = -1
    shipment.discounted_cost.should == 9
  end

  it "#tax_total with included taxes" do
    shipment = Spree::Shipment.new
    expect(shipment.tax_total).to eq(0)
    shipment.included_tax_total = 10
    expect(shipment.tax_total).to eq(10)
  end

  it "#tax_total with additional taxes" do
    shipment = Spree::Shipment.new
    expect(shipment.tax_total).to eq(0)
    shipment.additional_tax_total = 10
    expect(shipment.tax_total).to eq(10)
  end

  it "#final_price" do
    shipment = Spree::Shipment.new
    shipment.cost = 10
    shipment.promo_total = -2
    shipment.included_tax_total = 1
    expect(shipment.final_price).to eq(9)
  end

  context "manifest" do
    let(:order) { Spree::Order.create }
    let(:variant) { create(:variant) }
    let!(:line_item) { order.contents.add variant }
    let!(:shipment) { order.create_proposed_shipments.first }

    it "returns variant expected" do
      expect(shipment.manifest.first.variant).to eq variant
    end

    context "variant was removed" do
      before { variant.destroy }

      it "still returns variant expected" do
        expect(shipment.manifest.first.variant).to eq variant
      end
    end
  end

  context 'shipping_rates' do
    let(:shipment) { create(:shipment) }
    let(:shipping_method1) { create(:shipping_method) }
    let(:shipping_method2) { create(:shipping_method) }
    let(:shipping_rates) { [
      Spree::ShippingRate.new(shipping_method: shipping_method1, cost: 10.00, selected: true),
      Spree::ShippingRate.new(shipping_method: shipping_method2, cost: 20.00)
    ] }

    it 'returns shipping_method from selected shipping_rate' do
      shipment.shipping_rates.delete_all
      shipment.shipping_rates.create shipping_method: shipping_method1, cost: 10.00, selected: true
      shipment.shipping_method.should eq shipping_method1
    end

    context 'refresh_rates' do
      let(:mock_estimator) { double('estimator', shipping_rates: shipping_rates) }
      before { shipment.stub(:can_get_rates?){ true } }

      it 'should request new rates, and maintain shipping_method selection' do
        Spree::Stock::Estimator.should_receive(:new).with(shipment.order).and_return(mock_estimator)
        shipment.stub(shipping_method: shipping_method2)

        shipment.refresh_rates.should == shipping_rates
        shipment.reload.selected_shipping_rate.shipping_method_id.should == shipping_method2.id
      end

      it 'should handle no shipping_method selection' do
        Spree::Stock::Estimator.should_receive(:new).with(shipment.order).and_return(mock_estimator)
        shipment.stub(shipping_method: nil)
        shipment.refresh_rates.should == shipping_rates
        shipment.reload.selected_shipping_rate.should_not be_nil
      end

      it 'should not refresh if shipment is shipped' do
        Spree::Stock::Estimator.should_not_receive(:new)
        shipment.shipping_rates.delete_all
        shipment.stub(shipped?: true)
        shipment.refresh_rates.should == []
      end

      it "can't get rates without a shipping address" do
        shipment.order(ship_address: nil)
        expect(shipment.refresh_rates).to eq([])
      end

      context 'to_package' do
        let(:inventory_units) do
          [build(:inventory_unit, line_item: line_item, variant: variant, state: 'on_hand'),
           build(:inventory_unit, line_item: line_item, variant: variant, state: 'backordered')]
        end

        it 'should use symbols for states when adding contents to package' do
          shipment.stub_chain(:inventory_units, includes: inventory_units)
          package = shipment.to_package
          package.on_hand.count.should eq 1
          package.backordered.count.should eq 1
        end
      end
    end
  end

  context "#update!" do
    shared_examples_for "immutable once shipped" do
      it "should remain in shipped state once shipped" do
        shipment.state = 'shipped'
        shipment.should_receive(:update_columns).with(state: 'shipped', updated_at: kind_of(Time))
        shipment.update!(order)
      end
    end

    shared_examples_for "pending if backordered" do
      it "should have a state of pending if backordered" do
        shipment.stub(inventory_units: [mock_model(Spree::InventoryUnit, backordered?: true)])
        shipment.should_receive(:update_columns).with(state: 'pending', updated_at: kind_of(Time))
        shipment.update!(order)
      end
    end

    context "when order cannot ship" do
      before { order.stub can_ship?: false }
      it "should result in a 'pending' state" do
        shipment.should_receive(:update_columns).with(state: 'pending', updated_at: kind_of(Time))
        shipment.update!(order)
      end
    end

    context "when order is paid" do
      before { order.stub paid?: true }
      it "should result in a 'ready' state" do
        shipment.should_receive(:update_columns).with(state: 'ready', updated_at: kind_of(Time))
        shipment.update!(order)
      end
      it_should_behave_like 'immutable once shipped'
      it_should_behave_like 'pending if backordered'
    end

    context "when order has balance due" do
      before { order.stub paid?: false }
      it "should result in a 'pending' state" do
        shipment.state = 'ready'
        shipment.should_receive(:update_columns).with(state: 'pending', updated_at: kind_of(Time))
        shipment.update!(order)
      end
      it_should_behave_like 'immutable once shipped'
      it_should_behave_like 'pending if backordered'
    end

    context "when order has a credit owed" do
      before { order.stub payment_state: 'credit_owed', paid?: true }
      it "should result in a 'ready' state" do
        shipment.state = 'pending'
        shipment.should_receive(:update_columns).with(state: 'ready', updated_at: kind_of(Time))
        shipment.update!(order)
      end
      it_should_behave_like 'immutable once shipped'
      it_should_behave_like 'pending if backordered'
    end

    context "when shipment state changes to shipped" do
      before do
        shipment.stub(:send_shipped_email)
        shipment.stub(:update_order_shipment_state)
      end

      it "should call after_ship" do
        shipment.state = 'pending'
        shipment.should_receive :after_ship
        shipment.stub determine_state: 'shipped'
        shipment.should_receive(:update_columns).with(state: 'shipped', updated_at: kind_of(Time))
        shipment.update!(order)
      end

      # Regression test for #4347
      context "with adjustments" do
        before do
          shipment.adjustments << Spree::Adjustment.create(:label => "Label", :amount => 5)
        end

        it "transitions to shipped" do
          shipment.update_column(:state, "ready")
          lambda { shipment.ship! }.should_not raise_error
        end
      end
    end
  end

  context "when order is completed" do
    after { Spree::Config.set track_inventory_levels: true }

    before do
      order.stub completed?: true
      order.stub canceled?: false
    end

    context "with inventory tracking" do
      before { Spree::Config.set track_inventory_levels: true }

      it "should validate with inventory" do
        shipment.inventory_units = [create(:inventory_unit)]
        shipment.valid?.should be_true
      end
    end

    context "without inventory tracking" do
      before { Spree::Config.set track_inventory_levels: false }

      it "should validate with no inventory" do
        shipment.valid?.should be_true
      end
    end
  end

  context "#cancel" do
    it 'cancels the shipment' do
      shipment.order.stub(:update!)

      shipment.state = 'pending'
      shipment.should_receive(:after_cancel)
      shipment.cancel!
      shipment.state.should eq 'canceled'
    end

    it 'restocks the items' do
      shipment.stub_chain(inventory_units: [mock_model(Spree::InventoryUnit, state: "on_hand", line_item: line_item, variant: variant)])
      shipment.stock_location = mock_model(Spree::StockLocation)
      shipment.stock_location.should_receive(:restock).with(variant, 1, shipment)
      shipment.after_cancel
    end

    context "with backordered inventory units" do
      let(:order) { create(:order) }
      let(:variant) { create(:variant) }
      let(:other_order) { create(:order) }

      before do
        order.contents.add variant
        order.create_proposed_shipments

        other_order.contents.add variant
        other_order.create_proposed_shipments
      end

      it "doesn't fill backorders when restocking inventory units" do
        shipment = order.shipments.first
        expect(shipment.inventory_units.count).to eq 1
        expect(shipment.inventory_units.first).to be_backordered

        other_shipment = other_order.shipments.first
        expect(other_shipment.inventory_units.count).to eq 1
        expect(other_shipment.inventory_units.first).to be_backordered

        expect {
          shipment.cancel!
        }.not_to change { other_shipment.inventory_units.first.state }
      end
    end
  end

  context "#resume" do
    it 'will determine new state based on order' do
      shipment.order.stub(:update!)

      shipment.state = 'canceled'
      shipment.should_receive(:determine_state).and_return(:ready)
      shipment.should_receive(:after_resume)
      shipment.resume!
      shipment.state.should eq 'ready'
    end

    it 'unstocks them items' do
      shipment.stub_chain(inventory_units: [mock_model(Spree::InventoryUnit, line_item: line_item, variant: variant)])
      shipment.stock_location = mock_model(Spree::StockLocation)
      shipment.stock_location.should_receive(:unstock).with(variant, 1, shipment)
      shipment.after_resume
    end

    it 'will determine new state based on order' do
      shipment.order.stub(:update!)

      shipment.state = 'canceled'
      shipment.should_receive(:determine_state).twice.and_return('ready')
      shipment.should_receive(:after_resume)
      shipment.resume!
      # Shipment is pending because order is already paid
      shipment.state.should eq 'pending'
    end
  end

  context "#ship" do
    before do
      order.stub(:update!)
      shipment.stub(require_inventory: false, update_order: true, state: 'ready')
    end

    it "should update shipped_at timestamp" do
      shipment.stub(:send_shipped_email)
      shipment.stub(:update_order_shipment_state)
      shipment.ship!
      shipment.shipped_at.should_not be_nil
      # Ensure value is persisted
      shipment.reload
      shipment.shipped_at.should_not be_nil
    end

    it "should send a shipment email" do
      mail_message = double 'Mail::Message'
      shipment_id = nil
      Spree::ShipmentMailer.should_receive(:shipped_email) { |*args|
        shipment_id = args[0]
        mail_message
      }
      mail_message.should_receive :deliver
      shipment.stub(:update_order_shipment_state)
      shipment.ship!
      shipment_id.should == shipment.id
    end

    it "finalizes adjustments" do
      shipment.stub(:send_shipped_email)
      shipment.stub(:update_order_shipment_state)
      shipment.adjustments.each do |adjustment|
        expect(adjustment).to receive(:finalize!)
      end
      shipment.ship!
    end
  end

  context "#ready" do
    # Regression test for #2040
    it "cannot ready a shipment for an order if the order is unpaid" do
      order.stub(paid?: false)
      assert !shipment.can_ready?
    end
  end

  context "updates cost when selected shipping rate is present" do
    let(:shipment) { create(:shipment) }

    before { shipment.stub_chain :selected_shipping_rate, cost: 5 }

    it "updates shipment totals" do
      shipment.update_amounts
      shipment.reload.cost.should == 5
    end

    it "factors in additional adjustments to adjustment total" do
      shipment.adjustments.create!({
        :label => "Additional",
        :amount => 5,
        :included => false,
        :state => "closed"
      })
      shipment.update_amounts
      shipment.reload.adjustment_total.should == 5
    end

    it "does not factor in included adjustments to adjustment total" do
      shipment.adjustments.create!({
        :label => "Included",
        :amount => 5,
        :included => true,
        :state => "closed"
      })
      shipment.update_amounts
      shipment.reload.adjustment_total.should == 0
    end
  end

  context "changes shipping rate via general update" do
    let(:order) do
      Spree::Order.create(
        payment_total: 100, payment_state: 'paid', total: 100, item_total: 100
      )
    end

    let(:shipment) { Spree::Shipment.create order_id: order.id }

    let(:shipping_rate) do
      Spree::ShippingRate.create shipment_id: shipment.id, cost: 10
    end

    before do
      shipment.update_attributes_and_order selected_shipping_rate_id: shipping_rate.id
    end

    it "updates everything around order shipment total and state" do
      expect(shipment.cost.to_f).to eq 10
      expect(shipment.state).to eq 'pending'
      expect(shipment.order.total.to_f).to eq 110
      expect(shipment.order.payment_state).to eq 'balance_due'
    end
  end

  context "after_save" do
    context "line item changes" do
      before do
        shipment.cost = shipment.cost + 10
      end

      it "triggers adjustment total recalculation" do
        shipment.should_receive(:recalculate_adjustments)
        shipment.save
      end

      it "does not trigger adjustment recalculation if shipment has shipped" do
        shipment.state = 'shipped'
        shipment.should_not_receive(:recalculate_adjustments)
        shipment.save
      end
    end

    context "line item does not change" do
      it "does not trigger adjustment total recalculation" do
        shipment.should_not_receive(:recalculate_adjustments)
        shipment.save
      end
    end
  end

  context "currency" do
    it "returns the order currency" do
      shipment.currency.should == order.currency
    end
  end

  context "nil costs" do
    it "sets cost to 0" do
      shipment = Spree::Shipment.new
      shipment.valid?
      expect(shipment.cost).to eq 0
    end
  end

  context "#tracking_url" do
    it "uses shipping method to determine url" do
      shipping_method.should_receive(:build_tracking_url).with('1Z12345').and_return(:some_url)
      shipment.tracking = '1Z12345'

      shipment.tracking_url.should == :some_url
    end
  end

  context "set up new inventory units" do
    # let(:line_item) { double(
    let(:variant) { double("Variant", id: 9) }

    let(:inventory_units) { double }

    let(:params) do
      { variant_id: variant.id, state: 'on_hand', order_id: order.id, line_item_id: line_item.id }
    end

    before { shipment.stub inventory_units: inventory_units }

    it "associates variant and order" do
      expect(inventory_units).to receive(:create).with(params)
      unit = shipment.set_up_inventory('on_hand', variant, order, line_item)
    end
  end

  # Regression test for #3349
  context "#destroy" do
    it "destroys linked shipping_rates" do
      reflection = Spree::Shipment.reflect_on_association(:shipping_rates)
      reflection.options[:dependent] = :destroy
    end
  end

  # Regression test for #4072 (kinda)
  # The need for this was discovered in the research for #4702
  context "state changes" do
    before do
      # Must be stubbed so transition can succeed
      order.stub :paid? => true
    end

    it "are logged to the database" do
      shipment.state_changes.should be_empty
      expect(shipment.ready!).to be_true
      shipment.state_changes.count.should == 1
      state_change = shipment.state_changes.first
      expect(state_change.previous_state).to eq('pending')
      expect(state_change.next_state).to eq('ready')
    end
  end
end
