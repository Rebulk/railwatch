# The shape Rails 8's authentication generator writes
# (`resources :passwords, param: :token`): a live reset token in the path.
class PasswordsController < ApplicationController
  def edit
    render plain: "reset #{params[:token].size}"
  end

  def update
    render plain: "updated"
  end

  def accept
    render plain: "accepted"
  end

  def redirect_to_reset
    redirect_to edit_password_url("RESET_TOKEN_IN_REDIRECT")
  end

  def redirect_to_reset_preserving
    redirect_to "/resets/RESET_TOKEN_IN_307", status: :temporary_redirect
  end

  def boom
    raise ArgumentError, "reset failed"
  end
end
