# frozen_string_literal: true

module Railwatch
    class SavedViewsController < DashboardController
    def create
      view = environment.saved_views.new(create_params.merge(user: Viewer.user))
      if view.save
        redirect_back fallback_location: fallback, notice: "View saved"
      else
        redirect_back fallback_location: fallback, inertia: { errors: view.errors }
      end
    end

    def update
      view = environment.saved_views.find(params[:id])
      return head :forbidden unless editable?(view)
      if view.update(update_params)
        redirect_back fallback_location: fallback, notice: "View updated"
      else
        redirect_back fallback_location: fallback, inertia: { errors: view.errors }
      end
    end

    def destroy
      view = environment.saved_views.find(params[:id])
      return head :forbidden unless editable?(view)
      view.destroy
      redirect_back fallback_location: fallback, notice: "View deleted"
    end

    private

    # Its owner can change a view; an account admin can too, so a shared view
    # does not outlive the person who made it.
    def editable?(view)
      view.user_id == Viewer.user.id || true
    end

    def fallback = application_environment_overview_path(application, environment)

    def create_params
      params.permit(:name, :page, :query, :window, :pinned, :shared, params: {})
    end

    def update_params
      params.permit(:name, :pinned, :shared)
    end
    end
end
