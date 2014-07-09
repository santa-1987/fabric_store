require 'spec_helper'

module Spree
  describe Api::CheckoutsController do
    render_views

    before(:each) do
      stub_authentication!
      Spree::Config[:track_inventory_levels] = false
      country_zone = create(:zone, :name => 'CountryZone')
      @state = create(:state)
      @country = @state.country
      country_zone.members.create(:zoneable => @country)
      create(:stock_location)

      @shipping_method = create(:shipping_method, :zones => [country_zone])
      @payment_method = create(:credit_card_payment_method)
    end

    after do
      Spree::Config[:track_inventory_levels] = true
    end

    context "PUT 'update'" do
      let(:order) do
        order = create(:order_with_line_items)
        # Order should be in a pristine state
        # Without doing this, the order may transition from 'cart' straight to 'delivery'
        order.shipments.delete_all
        order
      end

      before(:each) do
        Order.any_instance.stub(:confirmation_required? => true)
        Order.any_instance.stub(:payment_required? => true)
      end

      it "should transition a recently created order from cart to address" do
        order.state.should eq "cart"
        order.email.should_not be_nil
        api_put :update, :id => order.to_param, :order_token => order.guest_token
        order.reload.state.should eq "address"
      end

      it "should transition a recently created order from cart to address with order token in header" do
        order.state.should eq "cart"
        order.email.should_not be_nil
        request.headers["X-Spree-Order-Token"] = order.guest_token
        api_put :update, :id => order.to_param
        order.reload.state.should eq "address"
      end

      it "can take line_items_attributes as a parameter" do
        line_item = order.line_items.first
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
                         :order => { :line_items_attributes => { 0 => { :id => line_item.id, :quantity => 1 } } }
        response.status.should == 200
        order.reload.state.should eq "address"
      end

      it "can take line_items as a parameter" do
        line_item = order.line_items.first
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
                         :order => { :line_items => { 0 => { :id => line_item.id, :quantity => 1 } } }
        response.status.should == 200
        order.reload.state.should eq "address"
      end

      it "will return an error if the order cannot transition" do
        pending "not sure if this test is valid"
        order.bill_address = nil
        order.save
        order.update_column(:state, "address")
        api_put :update, :id => order.to_param, :order_token => order.guest_token
        # Order has not transitioned
        response.status.should == 422
      end

      context "transitioning to delivery" do
        before do
          order.update_column(:state, "address")
        end

        let(:address) do
          {
            :firstname  => 'John',
            :lastname   => 'Doe',
            :address1   => '7735 Old Georgetown Road',
            :city       => 'Bethesda',
            :phone      => '3014445002',
            :zipcode    => '20814',
            :state_id   => @state.id,
            :country_id => @country.id
          }
        end

        it "can update addresses and transition from address to delivery" do
          api_put :update,
                  :id => order.to_param, :order_token => order.guest_token,
                  :order => {
                    :bill_address_attributes => address,
                    :ship_address_attributes => address
                  }
          json_response['state'].should == 'delivery'
          json_response['bill_address']['firstname'].should == 'John'
          json_response['ship_address']['firstname'].should == 'John'
          response.status.should == 200
        end

        # Regression test for #4498
        it "does not contain duplicate variant data in delivery return" do
          api_put :update,
                  :id => order.to_param, :order_token => order.guest_token,
                  :order => {
                    :bill_address_attributes => address,
                    :ship_address_attributes => address
                  }
          # Shipments manifests should not return the ENTIRE variant
          # This information is already present within the order's line items
          expect(json_response['shipments'].first['manifest'].first['variant']).to be_nil
          expect(json_response['shipments'].first['manifest'].first['variant_id']).to_not be_nil
        end
      end

      it "can update shipping method and transition from delivery to payment" do
        order.update_column(:state, "delivery")
        shipment = create(:shipment, :order => order)
        shipment.refresh_rates
        shipping_rate = shipment.shipping_rates.where(:selected => false).first
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => { :shipments_attributes => { "0" => { :selected_shipping_rate_id => shipping_rate.id, :id => shipment.id } } }
        response.status.should == 200
        # Find the correct shipment...
        json_shipment = json_response['shipments'].detect { |s| s["id"] == shipment.id }
        # Find the correct shipping rate for that shipment...
        json_shipping_rate = json_shipment['shipping_rates'].detect { |sr| sr["id"] == shipping_rate.id }
        # ... And finally ensure that it's selected
        json_shipping_rate['selected'].should be_true
        # Order should automatically transfer to payment because all criteria are met
        json_response['state'].should == 'payment'
      end

      it "can update payment method and transition from payment to confirm" do
        order.update_column(:state, "payment")
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => { :payments_attributes => [{ :payment_method_id => @payment_method.id }] }
        json_response['state'].should == 'confirm'
        json_response['payments'][0]['payment_method']['name'].should == @payment_method.name
        json_response['payments'][0]['amount'].should == order.total.to_s
        response.status.should == 200
      end

      it "can update payment method with source and transition from payment to confirm" do
        order.update_column(:state, "payment")
        source_attributes = {
          "number" => "4111111111111111",
          "month" => 1.month.from_now.month,
          "year" => 1.month.from_now.year,
          "verification_value" => "123",
          "name" => "Spree Commerce"
        }

        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => { :payments_attributes => [{ :payment_method_id => @payment_method.id.to_s }],
                      :payment_source => { @payment_method.id.to_s => source_attributes } }
        json_response['payments'][0]['payment_method']['name'].should == @payment_method.name
        json_response['payments'][0]['amount'].should == order.total.to_s
        response.status.should == 200
      end

      it "returns errors when source is missing attributes" do
        order.update_column(:state, "payment")
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => {
            :payments_attributes => [{ :payment_method_id => @payment_method.id.to_s }]
          },
          :payment_source => {
            @payment_method.id.to_s => { name: "Spree" }
          }

        response.status.should == 422
        cc_errors = json_response['errors']['payments.Credit Card']
        cc_errors.should include("Number can't be blank")
        cc_errors.should include("Month is not a number")
        cc_errors.should include("Year is not a number")
        cc_errors.should include("Verification Value can't be blank")
      end

      it "can transition from confirm to complete" do
        order.update_column(:state, "confirm")
        Spree::Order.any_instance.stub(:payment_required? => false)
        api_put :update, :id => order.to_param, :order_token => order.guest_token
        json_response['state'].should == 'complete'
        response.status.should == 200
      end

      it "returns the order if the order is already complete" do
        order.update_column(:state, "complete")
        api_put :update, :id => order.to_param, :order_token => order.guest_token
        json_response['number'].should == order.number
        response.status.should == 200
      end

      # Regression test for #3784
      it "can update the special instructions for an order" do
        instructions = "Don't drop it. (Please)"
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => { :special_instructions => instructions }
        expect(json_response['special_instructions']).to eql(instructions)
      end

      context "as an admin" do
        sign_in_as_admin!
        it "can assign a user to the order" do
          user = create(:user)
          # Need to pass email as well so that validations succeed
          api_put :update, :id => order.to_param, :order_token => order.guest_token,
            :order => { :user_id => user.id, :email => "guest@spreecommerce.com" }
          response.status.should == 200
          json_response['user_id'].should == user.id
        end
      end

      it "can assign an email to the order" do
        api_put :update, :id => order.to_param, :order_token => order.guest_token,
          :order => { :email => "guest@spreecommerce.com" }
        json_response['email'].should == "guest@spreecommerce.com"
        response.status.should == 200
      end

      it "can apply a coupon code to an order" do
        pending "ensure that the order totals are properly updated, see frontend orders_controller or checkout_controller as example"

        order.update_column(:state, "payment")
        PromotionHandler::Coupon.should_receive(:new).with(order).and_call_original
        PromotionHandler::Coupon.any_instance.should_receive(:apply).and_return({:coupon_applied? => true})
        api_put :update, :id => order.to_param, :order_token => order.guest_token, :order => { :coupon_code => "foobar" }
      end
    end

    context "PUT 'next'" do
      let!(:order) { create(:order_with_line_items) }
      it "cannot transition to address without a line item" do
        order.line_items.delete_all
        order.update_column(:email, "spree@example.com")
        api_put :next, :id => order.to_param, :order_token => order.guest_token
        response.status.should == 422
        json_response["errors"]["base"].should include(Spree.t(:there_are_no_items_for_this_order))
      end

      it "can transition an order to the next state" do
        order.update_column(:email, "spree@example.com")

        api_put :next, :id => order.to_param, :order_token => order.guest_token
        response.status.should == 200
        json_response['state'].should == 'address'
      end

      it "cannot transition if order email is blank" do
        order.update_columns(
          state: 'address',
          email: nil
        )

        api_put :next, :id => order.to_param, :order_token => order.guest_token
        response.status.should == 422
        json_response['error'].should =~ /could not be transitioned/
      end

      it "doesnt advance payment state if order has no payment" do
        order.update_column(:state, "payment")
        api_put :next, :id => order.to_param, :order_token => order.guest_token, :order => {}
        json_response["errors"]["base"].should include(Spree.t(:no_payment_found))
      end
    end

    context "PUT 'advance'" do
      let!(:order) { create(:order_with_line_items) }

      it 'continues to advance advances an order while it can move forward' do
        Spree::Order.any_instance.should_receive(:next).exactly(3).times.and_return(true, true, false)
        api_put :advance, :id => order.to_param, :order_token => order.guest_token
      end

      it 'returns the order' do
        api_put :advance, :id => order.to_param, :order_token => order.guest_token
        json_response['id'].should == order.id
      end
    end
  end
end
