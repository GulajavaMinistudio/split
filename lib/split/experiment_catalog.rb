# frozen_string_literal: true
module Split
  class ExperimentCatalog
    # Return all experiments
    def self.all
      # Call compact to prevent nil experiments from being returned -- seems to happen during gem upgrades
      Split.redis.smembers(:experiments).map { |e| find(e) }.compact
    end

    # Return experiments without a winner (considered "active") first
    def self.all_active_first
      all.partition { |e| !e.winner }.map { |es| es.sort_by(&:name) }
    end

    def self.find(name)
      return unless Split.redis.exists(name)
      Experiment.new(name).tap(&:load_from_redis)
    end

    def self.find_or_initialize(metric_descriptor, control = nil, *alternatives)
      # Check if array is passed to ab_test
      # e.g. ab_test('name', ['Alt 1', 'Alt 2', 'Alt 3'])
      if control.is_a?(Array) && alternatives.length.zero?
        alternatives = control[1..-1]
        control = control.first
      end

      experiment_name_with_version, goals = normalize_experiment(metric_descriptor)
      experiment_name = experiment_name_with_version.to_s.split(':')[0]
      Split::Experiment.new(experiment_name,
                            alternatives: [control].compact + alternatives, goals: goals)
    end

    def self.find_or_create(metric_descriptor, control = nil, *alternatives)
      experiment = find_or_initialize(metric_descriptor, control, *alternatives)
      experiment.save
    end

    def self.normalize_experiment(metric_descriptor)
      if metric_descriptor.is_a?(Hash)
        experiment_name = metric_descriptor.keys.first
        goals = Array(metric_descriptor.values.first)
      else
        experiment_name = metric_descriptor
        goals = []
      end
      [experiment_name, goals]
    end
  end
end
