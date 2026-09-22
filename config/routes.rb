# frozen_string_literal: true

Railwatch::Engine.routes.draw do
  post "beacon", to: "beacon#create"

  # The embedded dashboard. Same URL shape as the hosted platform so the
  # prebuilt bundle's route helpers resolve unchanged once js-routes knows
  # the mount point; a singleton install always answers for app 1, env 1.
  root to: redirect { |_p, req| "#{req.script_name}/apps/1/envs/1" }
  get "dashboard", to: redirect { |_p, req| "#{req.script_name}/apps/1/envs/1" }
  get "docs", to: redirect("https://railwatch.rebulk.com/docs")

  scope "apps/:application_id", as: :application do
    get "/", to: redirect { |p, req| "#{req.script_name}/apps/#{p[:application_id]}/envs/1" }
    scope "envs/:environment_id", as: :environment do
      get "/", to: "overview#show", as: :overview
      resources :requests, only: [ :index, :show ] do
        get "routes/:group_hash", to: "requests#route", on: :collection, as: :route
      end
      resources :jobs, only: [ :index, :show ] do
        get "classes/:group_hash", to: "jobs#klass", on: :collection, as: :klass
      end
      resources :scheduled_tasks, only: [ :index, :show ]
      resources :commands, only: [ :index, :show ]
      resources :executions, only: [ :show ]
      resources :queries, only: [ :index, :show ]
      resources :spans, only: [ :index, :show ]
      resources :profiles, only: [ :index, :show ]
      resources :attachments, only: [ :show ]
      get "traces/:trace_id", to: "traces#show", as: :trace
      resources :view_renders, path: "views", only: [ :index ]
      resources :transactions, only: [ :index ]
      resources :deprecations, only: [ :index ]
      resources :exceptions, only: [ :index ]
      resources :cache_events, path: "cache", only: [ :index ]
      resources :mails, path: "mail", only: [ :index ]
      resources :notifications, only: [ :index ]
      resources :broadcasts, only: [ :index ]
      resources :outgoing_requests, only: [ :index ]
      resources :llm_calls, path: "llm", only: [ :index ]
      resources :storage_ops, path: "storage", only: [ :index ]
      resources :logs, only: [ :index ]
      resources :people, path: "users", only: [ :index, :show ]
      resources :deploys, only: [ :index, :show ]
      resources :releases, only: [ :index, :show ]
      resources :visits, only: [ :index ]
      resources :processes, only: [ :index ]
      resource :monitoring_health, only: :show, controller: :monitoring_health
      resources :tenants, only: [ :index, :show ]
      resources :saved_views, only: [ :create, :update, :destroy ]
      resources :thresholds, only: [ :index, :create, :update, :destroy ]
      resources :anomaly_rules, only: [ :create, :update, :destroy ]
      resources :alerts, only: [ :index ]
    end
  end

  resources :issues, only: [ :index, :show, :update ] do
    resources :comments, only: [ :create ]
    post :bulk, on: :collection
    get :merge_candidates, on: :member
  end
  resources :alerts, only: [ :index ] do
    post :retry, on: :member
  end
end
