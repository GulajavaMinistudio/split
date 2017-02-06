# frozen_string_literal: true
module Split
  class Trial
    attr_accessor :experiment
    attr_accessor :metadata

    def initialize(attrs = {})
      self.experiment = attrs.delete(:experiment)
      self.alternative = attrs.delete(:alternative)
      self.metadata = attrs.delete(:metadata)

      @user = attrs.delete(:user)
      @options = attrs

      @alternative_choosen = false
    end

    def metadata
      @metadata ||= experiment.metadata[alternative.name] if experiment.metadata
    end

    def alternative
      @alternative ||= (@experiment.winner if @experiment.has_winner?)
    end

    def alternative=(alternative)
      @alternative =
        if alternative.is_a?(Split::Alternative)
          alternative
        else
          @experiment.alternatives.find { |a| a.name == alternative }
        end
    end

    def complete!(goals = [], context = nil)
      return unless alternative
      if Array(goals).empty?
        alternative.increment_completion
      else
        Array(goals).each { |g| alternative.increment_completion(g) }
      end

      run_callback context, Split.configuration.on_trial_complete
    end

    def score!(score_name, score_value = 1)
      return unless alternative
      alternative.increment_score(score_name, score_value)
    end

    # Choose an alternative, add a participant, and save the alternative choice on the user. This
    # method is guaranteed to only run once, and will skip the alternative choosing process if run
    # a second time.
    def choose!(context = nil)
      # only cleanup every now and then
      # lazy af method lul but is fine
      @user.cleanup_old_experiments! if rand(100) > 95

      # Only run the process once
      return alternative if @alternative_choosen

      chosen_alternative = @user[@experiment.key]
      if override_is_alternative?
        self.alternative = @options[:override]
        if should_store_alternative? && !chosen_alternative
          alternative.increment_participation
        end
      elsif @options[:disabled] || Split.configuration.disabled?
        self.alternative = @experiment.control
      elsif @experiment.has_winner?
        self.alternative = @experiment.winner
      else
        cleanup_old_versions

        if exclude_user?
          self.alternative = @experiment.control
        else
          value = chosen_alternative
          if value
            self.alternative = value
          else
            self.alternative = @experiment.next_alternative

            # Increment the number of participants since we are actually choosing a new alternative
            alternative.increment_participation

            run_callback context, Split.configuration.on_trial_choose
          end
        end
      end

      if override_is_alternative?
        if should_store_alternative? && !chosen_alternative
          @user[@experiment.key] = alternative.name
        end
      elsif should_store_alternative?
        @user[@experiment.key] = alternative.name
      end
      @alternative_choosen = true
      run_callback context, Split.configuration.on_trial unless @options[:disabled] || Split.configuration.disabled?
      alternative
    end

    private

    def run_callback(context, callback_name)
      context.send(callback_name, self) if callback_name && context.respond_to?(callback_name, true)
    end

    def override_is_alternative?
      @experiment.alternatives.map(&:name).include?(@options[:override])
    end

    def should_store_alternative?
      if @options[:override] || @options[:disabled]
        Split.configuration.store_override
      else
        !exclude_user?
      end
    end

    def cleanup_old_versions
      @user.cleanup_old_versions!(@experiment) if @experiment.version.positive?
    end

    def exclude_user?
      @options[:exclude] || @experiment.start_time.nil? || @user.max_experiments_reached?(@experiment.key)
    end
  end
end
