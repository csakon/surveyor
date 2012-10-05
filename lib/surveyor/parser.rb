%w(survey survey_section question_group question dependency dependency_condition answer validation validation_condition).each {|model| require model }
module Surveyor
  class ParserError < StandardError; end
  class Parser
    class << self; attr_accessor :options end

    # Attributes
    attr_accessor :context

    # Class methods
    def self.parse(str, options={})
      self.options = options
      Surveyor::Parser.rake_trace "\n"
      Surveyor::Parser.new.parse(str)
      Surveyor::Parser.rake_trace "\n"
    end
    def self.rake_trace(str)
      self.options ||= {}
      print str if self.options[:trace] == true
    end

    # Instance methods
    def initialize
      self.context = {}
    end
    def parse(str)
      instance_eval(str)
      return context[:survey]
    end
    # This method_missing does all the heavy lifting for the DSL
    def method_missing(missing_method, *args, &block)
      method_name, reference_identifier = missing_method.to_s.split("_", 2)
      type = full(method_name)

      Surveyor::Parser.rake_trace reference_identifier.blank? ? "#{type} " : "#{type}_#{reference_identifier} "

      # check for blocks
      raise Surveyor::ParserError, "Error: A #{type.humanize} cannot be empty" if block_models.include?(type) && !block_given?
      raise Surveyor::ParserError, "Error: Dropping the #{type.humanize} block like it's hot!" if !block_models.include?(type) && block_given?

      # parse and build
      type.classify.constantize.parse_and_build(context, args, method_name, reference_identifier)

      # evaluate and clear context for block models
      if block_models.include?(type)
        self.instance_eval(&block)
        if type == 'survey'
          Surveyor::Parser.rake_trace "\n"
          Surveyor::Parser.rake_trace context[:survey].save ? "saved. " : " not saved! #{context[type.to_sym].errors.each_full{|x| x }.join(", ")} "
        else
          context[type.to_sym].clear(context)
        end
      end
    end

    # Private methods
    private

    def full(method_name)
      case method_name.to_s
      when /^section$/; "survey_section"
      when /^g|grid|group|repeater$/; "question_group"
      when /^q|label|image$/; "question"
      when /^a$/; "answer"
      when /^d$/; "dependency"
      when /^c(ondition)?$/; context[:validation] ? "validation_condition" : "dependency_condition"
      when /^v$/; "validation"
      when /^dc(ondition)?$/; "dependency_condition"
      when /^vc(ondition)?$/; "validation_condition"
      else method_name
      end
    end
    def block_models
      %w(survey survey_section question_group)
    end
  end
end

# Surveyor models with extra parsing methods
class Survey < ActiveRecord::Base
  attr_accessor :context_reference
  attr_accessible :context_reference

  # block
  after_save :report_lost_and_duplicate_references
  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| true }
    context[:question_references] = {}
    context[:answer_references] = {}
    context[:bad_references] = []
    context[:duplicate_references] = []

    # build and set context
    title = args[0]
    context[:survey] = new({  :title => title,
                              :context_reference => context,
                              :reference_identifier => reference_identifier }.merge(args[1] || {}))
  end
  def clear(context)
    context.delete_if{|k,v| true }
    context[:question_references] = {}
    context[:answer_references] = {}
    context[:bad_references] = []
    context[:duplicate_references] = []
  end
  def report_lost_and_duplicate_references
    raise Surveyor::ParserError, "Bad references: #{context_reference[:bad_references].join("; ")}" unless context_reference[:bad_references].empty?
    raise Surveyor::ParserError, "Duplicate references: #{context_reference[:duplicate_references].join("; ")}" unless context_reference[:duplicate_references].empty?
  end
end
class SurveySection < ActiveRecord::Base
  # block

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| !%w(survey question_references answer_references bad_references duplicate_references).map(&:to_sym).include?(k)}

    # build and set context
    title = args[0]
    context[:survey_section] = context[:survey].sections.build({ :title => title,
                                                                 :display_order => context[:survey].sections.size }.merge(args[1] || {}))
  end
  def clear(context)
    context.delete_if{|k,v| !%w(survey question_references answer_references bad_references duplicate_references).map(&:to_sym).include?(k)}
  end
end
class QuestionGroup < ActiveRecord::Base
  # block

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| !%w(survey survey_section question_references answer_references bad_references duplicate_references).map(&:to_sym).include?(k)}

    # build and set context
    context[:question_group] = context[:question_group] = new({  :text => args[0] || "Question Group",
                                      :display_type => (original_method =~ /grid|repeater/ ? original_method : "default")}.merge(args[1] || {}))

  end
  def clear(context)
    context.delete_if{|k,v| !%w(survey survey_section question_references answer_references bad_references duplicate_references).map(&:to_sym).include?(k)}
  end
end
class Question < ActiveRecord::Base
  # nonblock

  # attributes
  attr_accessor :correct, :context_reference
  before_save :resolve_correct_answers

  attr_accessible :correct, :context_reference

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| %w(question dependency dependency_condition answer validation validation_condition).map(&:to_sym).include? k}

    # build and set context
    text = args[0] || "Question"
    context[:question] = context[:survey_section].questions.build({
      :context_reference => context,
      :question_group => context[:question_group],
      :reference_identifier => reference_identifier,
      :text => text,
      :display_type => (original_method =~ /label|image/ ? original_method : "default"),
      :display_order => context[:survey_section].questions.size }.merge(args[1] || {}))

    # keep reference for dependencies
    unless reference_identifier.blank?
      context[:duplicate_references].push "q_#{reference_identifier}" if context[:question_references].has_key?(reference_identifier)
      context[:question_references][reference_identifier] = context[:question]
    end

    # add grid answers
    if context[:question_group] && context[:question_group].display_type == "grid"
      (context[:grid_answers] || []).each do |grid_answer|
        a = context[:question].answers.build(grid_answer.attributes.reject{|k,v| %w(id api_id created_at updated_at).include?(k)})
        context[:answer_references][reference_identifier] ||= {} unless reference_identifier.blank?
        context[:answer_references][reference_identifier][grid_answer.reference_identifier] = a unless reference_identifier.blank? or grid_answer.reference_identifier.blank?
      end
    end
  end

  def resolve_correct_answers
    unless correct.blank? or reference_identifier.blank? or context_reference.blank?
      # Looking up references for quiz answers
      context_reference[:answer_references][reference_identifier] ||= {}
      context_reference[:answer_references][reference_identifier][correct].save
      Surveyor::Parser.rake_trace( (self.correct_answer_id = context_reference[:answer_references][reference_identifier][correct].id) ? "found correct answer:#{correct} " : "lost! correct answer:#{correct} ")
    end
  end
end
class Dependency < ActiveRecord::Base
  # nonblock

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| %w(dependency dependency_condition).map(&:to_sym).include? k}

    # build and set context
    if context[:question]
      context[:dependency] = context[:question].build_dependency(args[0] || {})
    elsif context[:question_group]
      context[:dependency] = context[:question_group].build_dependency(args[0] || {})
    end
  end
end
class DependencyCondition < ActiveRecord::Base
  # nonblock

  attr_accessor :question_reference, :answer_reference, :context_reference
  before_save :resolve_references

  attr_accessible :question_reference, :answer_reference, :context_reference

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| k == :dependency_condition}

    # build and set context
    a0, a1, a2 = args
    context[:dependency_condition] = context[:dependency].
      dependency_conditions.build(
        {
          :context_reference => context,
          :operator => a1 || "==",
          :question_reference => a0.to_s.gsub(/^q_/, ""),
          :rule_key => reference_identifier
        }.merge(
            a2.is_a?(Hash) ? a2 : { :answer_reference =>
                                      a2.to_s.gsub(/^a_/, "") }
          )
      )
  end

  def resolve_references
    if context_reference
      # Looking up references to questions and answers for linking the dependency objects
      if (self.question = context_reference[:question_references][question_reference])
        Surveyor::Parser.rake_trace("found q_#{question_reference} ")
      else
        Surveyor::Parser.rake_trace("lost q_#{question_reference}! ")
        context_reference[:bad_references].push "q_#{question_reference}"
      end
      unless answer_reference.blank?
        context_reference[:answer_references][question_reference] ||= {}
        if (self.answer = context_reference[:answer_references][question_reference][answer_reference])
          Surveyor::Parser.rake_trace( "found a_#{answer_reference} ")
        else
          Surveyor::Parser.rake_trace( "lost a_#{answer_reference}!")
          context_reference[:bad_references].push "q_#{question_reference}, a_#{answer_reference}"
        end
      end
    end
  end
end

class Answer < ActiveRecord::Base
  # nonblock

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| %w(answer validation validation_condition reference_identifier).map(&:to_sym).include? k}

    attrs = { :reference_identifier => reference_identifier }.merge(self.parse_args(args))

    # add answers to grid
    if context[:question_group] && context[:question_group].display_type == "grid"
      context[:grid_answers] ||= []
      context[:answer] = new({:display_order => [:grid_answers].size}.merge(attrs))
      context[:grid_answers] << context[:answer]
    else
      context[:answer] = context[:question].answers.build({:display_order => context[:question].answers.size}.merge(attrs))

    # keep reference for dependencies
    unless context[:question].reference_identifier.blank? or reference_identifier.blank?
      context[:answer_references][context[:question].reference_identifier] ||= {}
      context[:duplicate_references].push "q_#{context[:question].reference_identifier}, a_#{reference_identifier}" if context[:answer_references][context[:question].reference_identifier].has_key?(reference_identifier)
      context[:answer_references][context[:question].reference_identifier][reference_identifier] = context[:answer]
    end



    end
  end
  def self.parse_args(args)
    case args[0]
    when Hash # Hash
      self.text_args(args[0][:text]).merge(args[0])
    when String # (String, Hash) or (String, Symbol, Hash)
      self.text_args(args[0]).merge(self.hash_from args[1]).merge(args[2] || {})
    when Symbol # (Symbol, Hash) or (Symbol, Symbol, Hash)
      self.symbol_args(args[0]).merge(self.hash_from args[1]).merge(args[2] || {})
    else
      self.text_args(nil)
    end
  end
  def self.text_args(text = "Answer")
    {:text => text.to_s}
  end
  def self.hash_from(arg)
    arg.is_a?(Symbol) ? {:response_class => arg.to_s} : arg.is_a?(Hash) ? arg : {}
  end
  def self.symbol_args(arg)
    case arg
    when :other
      self.text_args("Other")
    when :other_and_string
      self.text_args("Other").merge({:response_class => "string"})
    when :none, :omit # is_exclusive erases and disables other checkboxes and input elements
      self.text_args(arg.to_s.humanize).merge({:is_exclusive => true})
    when :integer, :float, :date, :time, :datetime, :text, :datetime, :string
      self.text_args(arg.to_s.humanize).merge({:response_class => arg.to_s, :display_type => "hidden_label"})
    end
  end
end
class Validation < ActiveRecord::Base
  # nonblock

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| %w(validation validation_condition).map(&:to_sym).include? k}

    # build and set context
    context[:validation] = context[:answer].validations.build({:rule => "A"}.merge(args[0] || {}))
  end
end
class ValidationCondition < ActiveRecord::Base
  # nonblock

  def self.parse_and_build(context, args, original_method, reference_identifier)
    # clear context
    context.delete_if{|k,v| k == :validation_condition}

    # build and set context
    a0, a1 = args
    context[:validation_condition] = context[:validation].validation_conditions.build({
                                      :operator => a0 || "==",
                                      :rule_key => reference_identifier}.merge(a1 || {}))
  end
end
