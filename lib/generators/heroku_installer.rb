require "rails/generators"

module Decidim
  module Deploy
    class HerokuInstallerGenerator < Rails::Generators::Base
      source_root File.expand_path("../templates", __FILE__)

      def add_app_json
        template "app.json.erb", "app.json"
      end

      def set_review_apps_uploads_path_in_initializer
        gsub_file("config/initializers/decidim.rb", /^end/, <<-INITIALIZER_CONTENT)
  if ENV["HEROKU_APP_NAME"].present?
    config.base_uploads_path = ENV["HEROKU_APP_NAME"] + "/"
  end
end
INITIALIZER_CONTENT
      end

      def set_seeds_for_review_apps
        gsub_file("db/seeds.rb", "Decidim.seed!", <<-SEEDS_CONTENT)
if ENV["HEROKU_APP_NAME"].present?
  ENV["DECIDIM_HOST"] = ENV["HEROKU_APP_NAME"] + ".herokuapp.com"
  ENV["SEED"] = true
end
Decidim.seed!
        SEEDS_CONTENT
      end

      def add_production_gems
        insert_into_file("Gemfile", <<-PRODUCTION_GEMS, after: "group :production do")
  gem "dalli"
  gem "sendgrid-ruby"
  gem "newrelic_rpm"
  gem "lograge"
  gem "sentry-raven"
  gem "sidekiq"
        PRODUCTION_GEMS
      end

      def bundle_install
        Bundler.with_clean_env do
          run "bundle install"
        end
      end

      def add_context_for_sentry
        insert_into_file("app/controllers/decidim_controller.rb", <<-SENTRY_CONTEXT, after: "class DecidimController < ApplicationController")
  before_action :set_raven_context

  private

  def set_raven_context
    return unless Rails.application.secrets.sentry_enabled?
    Raven.user_context({id: try(:current_user).try(:id)}.merge(session))
    Raven.extra_context(params: params.to_unsafe_h, url: request.url)
  end
        SENTRY_CONTEXT
      end

      def enable_sentry_for_production
        gsub_file("config/secrets.yml", "default: &default", <<-SENTRY_DEFAULT)
default: &default
  sentry_enabled: false
        SENTRY_DEFAULT
        gsub_file("config/secrets.yml", "smtp_authentication: \"plain\"", <<-SENTRY_DEFAULT_PROD)
  smtp_authentication: "plain"
  sentry_enabled: true
        SENTRY_DEFAULT_PROD
      end

      def set_dalli_as_cache_store
        gsub_file("config/environments/production.rb", "# config.cache_store = :mem_cache_store", <<-DALLI_CONFIG)
  if ENV["MEMCACHEDCLOUD_SERVERS"].present?
    config.cache_store = :dalli_store, ENV["MEMCACHEDCLOUD_SERVERS"].split(","), {
      username: ENV["MEMCACHEDCLOUD_USERNAME"], password: ENV["MEMCACHEDCLOUD_PASSWORD"]
    }
  end
        DALLI_CONFIG
      end

      def lograge_config
        environment(nil, env: "production") do
"  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.custom_options = lambda do |event|
    {
      remote_ip: event.payload[:remote_ip],
      params: event.payload[:params].except('controller', 'action', 'format', 'utf8'),
      user_id: event.payload[:user_id],
      organization_id: event.payload[:organization_id],
      referer: event.payload[:referer],
    }
    end"
        end
      end

      def sidekiq_config
        environment(nil, env: "production") do
          "config.active_job.queue_adapter = :sidekiq"
        end
        prepend_to_file("config/routes.rb", "require \"sidekiq/web\"")
        route "authenticate :user, lambda { |u| u.roles.include?(\"admin\") } do
    mount Sidekiq::Web => '/sidekiq'
  end"
      end

      def add_procfile
        template "procfile.erb", "Procfile"
      end

      def add_sidekiq_config
        template "sidekiq_config.yml.erb", "config/sidekiq.yml"
      end

      private

      def app_name
        Rails.application.class.parent.name.underscore
      end
    end
  end
end
