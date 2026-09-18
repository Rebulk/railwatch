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

    # Its owner can change a view, and only its owner. The platform also lets
    # an account admin, so a shared view does not outlive the person who made
    # it; embedded mode has no account and no admin, and `|| true` here let
    # every dashboard user edit and delete everyone else's views. An app whose
    # dashboard_user resolver returns one identity for everybody is unaffected
    # either way: one owner, one editor.
    def editable?(view)
      view.viewer_id.to_s == Viewer.user.id.to_s
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
