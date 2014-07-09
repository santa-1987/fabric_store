require 'spec_helper'

module Spree
  describe OrdersController do
    ORDER_TOKEN = 'ORDER_TOKEN'

    let(:user) { create(:user) }
    let(:guest_user) { create(:user) }
    let(:order) { Spree::Order.create }

    it 'should understand order routes with token' do
      spree.token_order_path('R123456', 'ABCDEF').should == '/orders/R123456/token/ABCDEF'
    end

    context 'when an order exists in the cookies.signed' do
      let(:token) { 'some_token' }
      let(:specified_order) { create(:order) }

      before do
        controller.stub :current_order => order
        controller.stub :spree_current_user => user
      end

      context '#populate' do
        it 'should check if user is authorized for :edit' do
          controller.should_receive(:authorize!).with(:edit, order, token)
          spree_post :populate, :token => token
        end
        it "should check against the specified order" do
          controller.should_receive(:authorize!).with(:edit, specified_order, token)
          spree_post :populate, :id => specified_order.number, :token => token
        end
      end

      context '#edit' do
        it 'should check if user is authorized for :edit' do
          controller.should_receive(:authorize!).with(:edit, order, token)
          spree_get :edit, :token => token
        end
        it "should check against the specified order" do
          controller.should_receive(:authorize!).with(:edit, specified_order, token)
          spree_get :edit, :id => specified_order.number, :token => token
        end
      end

      context '#update' do
        it 'should check if user is authorized for :edit' do
          order.stub :update_attributes
          controller.should_receive(:authorize!).with(:edit, order, token)
          spree_post :update, :order => { :email => "foo@bar.com" }, :token => token
        end
        it "should check against the specified order" do
          order.stub :update_attributes
          controller.should_receive(:authorize!).with(:edit, specified_order, token)
          spree_post :update, :order => { :email => "foo@bar.com" }, :id => specified_order.number, :token => token
        end
      end

      context '#empty' do
        it 'should check if user is authorized for :edit' do
          controller.should_receive(:authorize!).with(:edit, order, token)
          spree_post :empty, :token => token
        end
        it "should check against the specified order" do
          controller.should_receive(:authorize!).with(:edit, specified_order, token)
          spree_post :empty, :id => specified_order.number, :token => token
        end
      end

      context "#show" do
        it "should check against the specified order" do
          controller.should_receive(:authorize!).with(:edit, specified_order, token)
          spree_get :show, :id => specified_order.number, :token => token
        end
      end
    end

    context 'when no authenticated user' do
      let(:order) { create(:order, :number => 'R123') }

      context '#show' do
        context 'when token parameter present' do
          it 'always ooverride existing token when passing a new one' do
            cookies.signed[:guest_token] = "soo wrong"
            spree_get :show, { :id => 'R123', :token => order.guest_token }
            cookies.signed[:guest_token].should == order.guest_token
          end

          it 'should store as guest_token in session' do
            spree_get :show, {:id => 'R123', :token => order.guest_token }
            cookies.signed[:guest_token].should == order.guest_token
          end
        end

        context 'when no token present' do
          it 'should respond with 404' do
            spree_get :show, {:id => 'R123'}
            response.code.should == '404'
          end
        end
      end
    end
  end
end
