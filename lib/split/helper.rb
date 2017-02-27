# frozen_string_literal: true
module Split
  module Helper
    OVERRIDE_PARAM_NAME = 'ab_test'.freeze

    module_function

    def with_user(user)
      original_ab_user = @ab_user
      original_method = defined?(current_user) && method(:current_user)
      return yield unless user
      begin
        define_singleton_method(:current_user) do
          user
        end
        redis_adapter = Split::Persistence::RedisAdapter.with_config(
          lookup_by: ->(context) { context.send(:current_user).try(:id) },
          expire_seconds: 2_592_000
        ).new(self)
        @ab_user = User.new(self, redis_adapter)

        yield
      rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
        raise unless Split.configuration.db_failover
        Split.configuration.db_failover_on_db_error.call(e)
      ensure
        @ab_user = original_ab_user
        if original_method
          define_singleton_method(:current_user) do
            original_method.call
          end
        end
      end
    end

    def ab_test(experiment_name, control = nil, *_alternatives, user: nil)
      with_user(user) do
        experiment_name = experiment_name.keys[0] if experiment_name.is_a? Hash
        experiment = ExperimentCatalog.find_or_initialize(experiment_name)
        unless experiment.valid? || control
          raise ::Split::ExperimentNotFound, "Experiment #{experiment_name} not correctly defined in configuration."
        end

        # at this point, it is either experiment exists in config or caller passes control
        begin
          if ::Split.configuration.enabled && experiment.valid?
            experiment.save
            trial = Trial.new(
              user: ab_user, experiment: experiment,
              override: override_alternative(experiment.name), exclude: exclude_visitor?,
              disabled: split_generically_disabled?
            )
            alternative = trial.choose!(self).name
          else
            alternative =
              if ::Split.configuration.enabled && experiment.has_winner? # backward compatibility with inline config
                experiment.winner.name
              else
                control_variable(control || experiment.control)
              end
          end
        rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
          raise(e) unless Split.configuration.db_failover
          Split.configuration.db_failover_on_db_error.call(e)

          if Split.configuration.db_failover_allow_parameter_override
            alternative = override_alternative(experiment.name) if override_present?(experiment.name)
            alternative = control_variable(experiment.control) if split_generically_disabled?
          end
        ensure
          alternative ||= control_variable(control || experiment.control)
        end

        if block_given?
          metadata = defined?(trial) && trial ? trial.metadata : {}
          yield(alternative, metadata)
        else
          alternative
        end
      end
    end

    def reset!(experiment)
      deleted_keys = [experiment.key]
      experiment.scores.each do |score_name|
        deleted_keys << experiment.scored_key(score_name)
      end
      ab_user.delete(*deleted_keys)
    end

    def finish_experiment(experiment, options = { reset: true })
      return true if experiment.has_winner?

      is_finished, chosen_alternative = ab_user.multi_get(experiment.finished_key, experiment.key)
      should_reset = experiment.resettable? && options[:reset]
      return true if is_finished && !should_reset

      alternative_name = chosen_alternative
      trial = Trial.new(user: ab_user, experiment: experiment, alternative: alternative_name)
      trial.complete!(options[:goals], self)

      if should_reset
        reset!(experiment)
      else
        ab_user[experiment.finished_key] = true
      end
    end

    def ab_finished(metric_descriptor, options = { reset: true, user: nil })
      with_user(options[:user]) do
        begin
          return if exclude_visitor? || Split.configuration.disabled?
          metric_descriptor, goals = normalize_metric(metric_descriptor)
          experiments = Metric.possible_experiments(metric_descriptor)

          if experiments.any?
            experiments.each do |experiment|
              finish_experiment(experiment, options.merge(goals: goals))
            end
          end
        rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
          raise unless Split.configuration.db_failover
          Split.configuration.db_failover_on_db_error.call(e)
        end
      end
    end

    def ab_test_result(experiment_name, options = { user: nil })
      with_user(options[:user]) do
        begin
          experiment = ExperimentCatalog.find(experiment_name)
          return nil unless experiment
          ab_user[experiment.key]
        rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
          raise unless Split.configuration.db_failover
          Split.configuration.db_failover_on_db_error.call(e)
        end
      end
    end

    def unscored_user_experiments(score_name, options = { user: nil })
      with_user(options[:user]) do
        Score.possible_experiments(score_name).reject do |experiment|
          already_scored = ab_user[experiment.scored_key(score_name)]
          experiment.has_winner? || already_scored
        end
      end
    end

    def ab_score(score_name, score_value = 1, options = { user: nil })
      with_user(options[:user]) do
        begin
          return if exclude_visitor? || Split.configuration.disabled?
          score_name = score_name.to_s
          trials = unscored_user_experiments(score_name).map do |experiment|
            Trial.new(user: ab_user, experiment: experiment, alternative: ab_user[experiment.key])
          end
          Split.redis.pipelined do
            trials.each do |trial|
              trial.score!(score_name, score_value)
            end
          end
        rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
          raise unless Split.configuration.db_failover
          Split.configuration.db_failover_on_db_error.call(e)
        end
      end
    end

    def ab_add_delayed_score(score_name, label, score_value = 1, ttl = 60 * 60 * 24, options = { user: nil })
      with_user(options[:user]) do
        begin
          return if exclude_visitor? || Split.configuration.disabled?
          score_name = score_name.to_s
          unscored_experiments = unscored_user_experiments(score_name)
          alternatives = unscored_experiments.map do |experiment|
            Alternative.new(ab_user[experiment.key], experiment)
          end.select do |alternative|
            alternative.scores.include?(score_name)
          end
          Split.redis.multi do
            Score.add_delayed(score_name, label, alternatives, score_value, ttl)
            unscored_experiments.each do |experiment|
              ab_user[experiment.scored_key(score_name)] = true
            end
          end
        rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
          raise unless Split.configuration.db_failover
          Split.configuration.db_failover_on_db_error.call(e)
        end
      end
    end

    def ab_apply_delayed_score(score_name, label)
      return if Split.configuration.disabled?
      Score.apply_delayed(score_name.to_s, label)
    rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
      raise unless Split.configuration.db_failover
      Split.configuration.db_failover_on_db_error.call(e)
    end

    def ab_score_alternative(experiment_name, alternative_name, score_name, score_value = 1)
      return if Split.configuration.disabled?

      score_name = score_name.to_s
      alternative_name = alternative_name.to_s
      experiment = ExperimentCatalog.find(experiment_name)
      return unless experiment && experiment.scores.include?(score_name)

      trial = Trial.new(experiment: experiment, alternative: alternative_name)
      trial.score!(score_name, score_value)
    rescue Errno::ECONNREFUSED, Redis::BaseError, SocketError => e
      raise unless Split.configuration.db_failover
      Split.configuration.db_failover_on_db_error.call(e)
    end

    def override_present?(experiment_name)
      override_alternative(experiment_name)
    end

    def override_alternative(experiment_name)
      defined?(params) && params[OVERRIDE_PARAM_NAME] && params[OVERRIDE_PARAM_NAME][experiment_name]
    end

    def split_generically_disabled?
      defined?(params) && params['SPLIT_DISABLE']
    end

    def ab_user
      @ab_user ||= User.new(self)
    end

    def exclude_visitor?
      instance_eval(&Split.configuration.ignore_filter) || is_ignored_ip_address? || is_robot?
    end

    def is_robot?
      defined?(request) && request.user_agent =~ Split.configuration.robot_regex
    end

    def is_ignored_ip_address?
      return false if Split.configuration.ignore_ip_addresses.empty?

      Split.configuration.ignore_ip_addresses.each do |ip|
        return true if defined?(request) && (request.ip == ip || (ip.class == Regexp && request.ip =~ ip))
      end
      false
    end

    def active_experiments
      ab_user.active_experiments
    end

    def normalize_metric(metric_descriptor)
      if metric_descriptor.is_a?(Hash)
        experiment_name = metric_descriptor.keys.first
        goals = Array(metric_descriptor.values.first)
      else
        experiment_name = metric_descriptor
        goals = []
      end
      [experiment_name, goals]
    end

    def control_variable(control)
      control.is_a?(Hash) ? control.keys.first.to_s : control.to_s
    end
  end
end
