# frozen_string_literal: true

Railwatch::Engine.routes.draw do
  post "beacon", to: "beacon#create"
  root to: "dashboard#show"
  get "dashboard", to: "dashboard#show"
  # Same URL shape as the hosted platform, so the dashboard bundle's route
  # helpers resolve unchanged once js-routes knows the mount point.
  scope "apps/:application_id", as: :application do
    get "/", to: "dashboard#show"
    scope "envs/:environment_id", as: :environment do
      get "/", to: "dashboard#show", as: :overview
      get "requests", to: "dashboard#requests"
      get "jobs", to: "dashboard#stub"
      get "queries", to: "dashboard#stub"
      get "exceptions", to: "dashboard#stub"
      get "logs", to: "dashboard#stub"
    end
  end
  get "issues", to: "dashboard#stub"
  get "alerts", to: "dashboard#stub"
end
