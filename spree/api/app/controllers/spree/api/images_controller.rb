module Spree
  module Api
    class ImagesController < Spree::Api::BaseController

      def show
        @image = Image.accessible_by(current_ability, :read).find(params[:id])
        respond_with(@image)
      end

      def create
        authorize! :create, Image
        @image = scope.images.create(image_params)
        respond_with(@image, :status => 201, :default_template => :show)
      end

      def update
        @image = scope.images.accessible_by(current_ability, :update).find(params[:id])
        @image.update_attributes(image_params)
        respond_with(@image, :default_template => :show)
      end

      def destroy
        @image = scope.images.accessible_by(current_ability, :destroy).find(params[:id])
        @image.destroy
        respond_with(@image, :status => 204)
      end

      private
        def image_params
          params.require(:image).permit(permitted_image_attributes)
        end

        def scope
          if params[:product_id]
            scope = Spree::Product.friendly.find(params[:product_id])
          elsif params[:variant_id]
            scope = Spree::Variant.find(params[:variant_id])
          end
        end
    end
  end
end
