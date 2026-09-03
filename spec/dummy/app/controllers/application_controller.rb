class ApplicationController < ActionController::Base
  before_action { Current.user = User.first }
end
