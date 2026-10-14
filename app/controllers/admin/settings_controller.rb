module Admin
  class SettingsController < BaseController
    def show
      @form = StoreSettingsForm.new(StoreSetting.current)
      @collecting_tax = @form.setting.checkout_tax_rate_id.present?
    end

    def update
      @form = StoreSettingsForm.new(StoreSetting.current, settings_params)
      return redirect_to(admin_settings_path, notice: "Settings saved.") if @form.save

      # From a fresh read: the form's copy holds the rejected values.
      @collecting_tax = StoreSetting.current.checkout_tax_rate_id.present?
      render :show, status: :unprocessable_entity
    end

    private

    def settings_params
      params.fetch(:settings, {}).permit(:shipping, :pickup_instructions, :tax_enabled, :tax_rate)
    end
  end
end
