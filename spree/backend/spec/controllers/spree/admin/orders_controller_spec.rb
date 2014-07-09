require 'spec_helper'
require 'cancan'
require 'spree/testing_support/bar_ability'

# Ability to test access to specific model instances
class OrderSpecificAbility
  include CanCan::Ability

  def initialize(user)
    can [:admin, :manage], Spree::Order, :number => 'R987654321'
  end
end

describe Spree::Admin::OrdersController do

  context "with authorization" do
    stub_authorization!

    before do
      request.env["HTTP_REFERER"] = "http://localhost:3000"

      # ensure no respond_overrides are in effect
      if Spree::BaseController.spree_responders[:OrdersController].present?
        Spree::BaseController.spree_responders[:OrdersController].clear
      end
    end

    let(:order) { mock_model(Spree::Order, :completed? => true, :total => 100, :number => 'R123456789') }
    before { Spree::Order.stub :find_by_number! => order }

    context "#approve" do
      it "approves an order" do
        expect(order).to receive(:approved_by).with(controller.try_spree_current_user)
        spree_put :approve, id: order.number
        expect(flash[:success]).to eq Spree.t(:order_approved)
      end
    end

    context "#cancel" do
      it "cancels an order" do
        expect(order).to receive(:cancel!)
        spree_put :cancel, id: order.number
        expect(flash[:success]).to eq Spree.t(:order_canceled)
      end
    end

    context "#resume" do
      it "resumes an order" do
        expect(order).to receive(:resume!)
        spree_put :resume, id: order.number
        expect(flash[:success]).to eq Spree.t(:order_resumed)
      end
    end

    context "pagination" do
      it "can page through the orders" do
        spree_get :index, :page => 2, :per_page => 10
        assigns[:orders].offset_value.should == 10
        assigns[:orders].limit_value.should == 10
      end
    end

    # Test for #3346
    context "#new" do
      it "a new order has the current user assigned as a creator" do
        spree_get :new
        assigns[:order].created_by.should == controller.try_spree_current_user
      end
    end

    # Regression test for #3684
    context "#edit" do
      it "does not refresh rates if the order is completed" do
        order.stub :completed? => true
        order.should_not_receive :refresh_shipment_rates
        spree_get :edit, :id => order.number
      end

      it "does refresh the rates if the order is incomplete" do
        order.stub :completed? => false
        order.should_receive :refresh_shipment_rates
        spree_get :edit, :id => order.number
      end
    end

    # Test for #3919
    context "search" do
      let(:user) { create(:user) }

      before do
        controller.stub :spree_current_user => user
        user.spree_roles << Spree::Role.find_or_create_by(name: 'admin')

        create(:completed_order_with_totals)
        expect(Spree::Order.count).to eq 1
      end

      it "does not display duplicated results" do
        spree_get :index, q: {
          line_items_variant_id_in: Spree::Order.first.variants.map(&:id)
        }
        expect(assigns[:orders].map { |o| o.number }.count).to eq 1
      end
    end
  end

  context '#authorize_admin' do
    let(:user) { create(:user) }
    let(:order) { create(:completed_order_with_totals, :number => 'R987654321') }

    before do
      Spree::Order.stub :find_by_number! => order
      controller.stub :spree_current_user => user
    end

    it 'should grant access to users with an admin role' do
      user.spree_roles << Spree::Role.find_or_create_by(name: 'admin')
      spree_post :index
      response.should render_template :index
    end

    it 'should grant access to users with an bar role' do
      user.spree_roles << Spree::Role.find_or_create_by(name: 'bar')
      Spree::Ability.register_ability(BarAbility)
      spree_post :index
      response.should render_template :index
      Spree::Ability.remove_ability(BarAbility)
    end

    it 'should deny access to users with an bar role' do
      order.stub(:update_attributes).and_return true
      order.stub(:user).and_return Spree.user_class.new
      order.stub(:token).and_return nil
      user.spree_roles.clear
      user.spree_roles << Spree::Role.find_or_create_by(name: 'bar')
      Spree::Ability.register_ability(BarAbility)
      spree_put :update, { :id => 'R123' }
      response.should redirect_to('/unauthorized')
      Spree::Ability.remove_ability(BarAbility)
    end

    it 'should deny access to users without an admin role' do
      user.stub :has_spree_role? => false
      spree_post :index
      response.should redirect_to('/unauthorized')
    end

    it 'should restrict returned order(s) on index when using OrderSpecificAbility' do
      number = order.number

      3.times { create(:completed_order_with_totals) }
      Spree::Order.complete.count.should eq 4
      Spree::Ability.register_ability(OrderSpecificAbility)

      user.stub :has_spree_role? => false
      spree_get :index
      response.should render_template :index
      assigns['orders'].size.should eq 1
      assigns['orders'].first.number.should eq number
      Spree::Order.accessible_by(Spree::Ability.new(user), :index).pluck(:number).should eq  [number]
    end
  end

  context "order number not given" do
    stub_authorization!

    it "raise active record not found" do
      expect {
        spree_get :edit, id: nil
      }.to raise_error ActiveRecord::RecordNotFound
    end
  end
end
