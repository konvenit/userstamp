module Ddb #:nodoc:
  module Userstamp
    # Determines what default columns to use for recording the current stamper.
    # By default this is set to false, so the plug-in will use columns named
    # <tt>creator_id</tt>, <tt>updater_id</tt>, and <tt>deleter_id</tt>.
    #
    # To turn compatibility mode on, place the following line in your environment.rb
    # file:
    #
    #   Ddb::Userstamp.compatibility_mode = true
    #
    # This will cause the plug-in to use columns named <tt>created_by</tt>,
    # <tt>updated_by</tt>, and <tt>deleted_by</tt>.
    mattr_accessor :compatibility_mode
    @@compatibility_mode = false

    mattr_accessor :stamper_klass
    @@stamper_klass = nil
    # Extends the stamping functionality of ActiveRecord by automatically recording the model
    # responsible for creating, updating, and deleting the current object. See the Stamper
    # and Userstamp modules for further documentation on how the entire process works.
    module Stampable
      def self.included(base) #:nodoc:
        super

        base.extend(ClassMethods)
        base.class_eval do
          include InstanceMethods

          # Should ActiveRecord record userstamps? Defaults to true.
          class_attribute  :record_userstamp
          self.record_userstamp = true

          # Which class is responsible for stamping? Defaults to :user.
          class_attribute  :stamper_class_name

          # What column should be used for the creator stamp?
          # Defaults to :creator_id when compatibility mode is off
          # Defaults to :created_by when compatibility mode is on
          class_attribute  :creator_attribute

          # What column should be used for the updater stamp?
          # Defaults to :updater_id when compatibility mode is off
          # Defaults to :updated_by when compatibility mode is on
          class_attribute  :updater_attribute

          # What column should be used for the deleter stamp?
          # Defaults to :deleter_id when compatibility mode is off
          # Defaults to :deleted_by when compatibility mode is on
          class_attribute  :deleter_attribute

          #you can change your link method
          # default 'belongs_to'
          class_attribute  :link_method

          #polymorphic stampers
          class_attribute  :updater_type_attribute
          class_attribute  :creator_type_attribute
          class_attribute  :deleter_type_attribute
          class_attribute  :polymorphic

          self.stampable
        end
      end

      module ClassMethods
        # This method is automatically called on for all classes that inherit from
        # ActiveRecord, but if you need to customize how the plug-in functions, this is the
        # method to use. Here's an example:
        #
        #   class Post < ActiveRecord::Base
        #     stampable :stamper_class_name => :person,
        #               :creator_attribute  => :create_user,
        #               :updater_attribute  => :update_user,
        #               :deleter_attribute  => :delete_user
        #   end
        #
        # The method will automatically setup all the associations, and create <tt>before_save</tt>
        # and <tt>before_create</tt> filters for doing the stamping.
        def stampable(options = {})
          defaults  = {
            :stamper_class_name => :user,
            :link_method => :belongs_to,
            :polymorphic => false,
            :creator_attribute  => Ddb::Userstamp.compatibility_mode ? :created_by : :creator_id,
            :updater_attribute  => Ddb::Userstamp.compatibility_mode ? :updated_by : :updater_id,
            :deleter_attribute  => Ddb::Userstamp.compatibility_mode ? :deleted_by : :deleter_id,
            :updater_type_attribute => Ddb::Userstamp.compatibility_mode ? :updated_type : :updater_type,
            :creator_type_attribute => Ddb::Userstamp.compatibility_mode ? :created_type : :creator_type,
            :deleter_type_attribute => Ddb::Userstamp.compatibility_mode ? :deleted_type : :updater_type
          }.merge(options)

          self.stamper_class_name = defaults[:stamper_class_name].to_sym
          self.creator_attribute  = defaults[:creator_attribute].to_sym
          self.updater_attribute  = defaults[:updater_attribute].to_sym
          self.deleter_attribute  = defaults[:deleter_attribute].to_sym

          self.updater_type_attribute  = defaults[:updater_type_attribute].to_sym
          self.creator_type_attribute  = defaults[:creator_type_attribute].to_sym
          self.deleter_type_attribute  = defaults[:deleter_type_attribute].to_sym

          self.polymorphic  = defaults[:polymorphic]

          self.link_method = defaults[:link_method].to_sym

          class_eval do
            if self.polymorphic
              send(self.link_method, :creator, :polymorphic => true, :foreign_key => self.creator_attribute)
              send(self.link_method, :updater,:polymorphic => true, :foreign_key => self.updater_attribute)
            else
              send(self.link_method, :creator, :class_name => self.stamper_class_name.to_s.singularize.camelize,
                :foreign_key => self.creator_attribute)
              send(self.link_method, :updater, :class_name => self.stamper_class_name.to_s.singularize.camelize,
                 :foreign_key => self.updater_attribute)
            end

            before_validation :set_updater_attribute

            if defined?(Rails) and Rails::VERSION::MAJOR < 3
              before_validation_on_create :set_creator_attribute
            else
              before_validation :set_creator_attribute, :on => :create
            end

            if defined?(Caboose::Acts::Paranoid) or defined?(Paranoia)
              if self.polymorphic
                belongs_to :deleter,:polymorphic => true, :foreign_key => self.deleter_attribute
              else
                belongs_to :deleter, :class_name => self.stamper_class_name.to_s.singularize.camelize,
                  :foreign_key => self.deleter_attribute
              end
              before_destroy  :set_deleter_attribute
            end
          end
        end

        # Temporarily allows you to turn stamping off. For example:
        #
        #   Post.without_stamps do
        #     post = Post.find(params[:id])
        #     post.update_attributes(params[:post])
        #     post.save
        #   end
        def without_stamps
          original_value = self.record_userstamp
          self.record_userstamp = false
          yield
        ensure
          self.record_userstamp = original_value
        end

        def stamper_class #:nodoc:
          stamper_class_name.to_s.camelize.constantize rescue nil
        end
      end

      module InstanceMethods #:nodoc:
        private
        def has_stamper?
          !self.class.stamper_class.nil? && !self.class.stamper_class.stamper.nil? rescue false
        end

        def stamper_klass_type
          self.class.stamper_class.stamper_type || self.stamper_class_name.to_s.singularize.camelize
        end

        def set_creator_attribute
          return unless self.record_userstamp
          if respond_to?(self.creator_attribute.to_sym) && has_stamper? && self.send("#{self.creator_attribute}").blank?
            self.send("#{self.creator_attribute}=".to_sym, self.class.stamper_class.stamper)
            self.send("#{self.creator_type_attribute}=".to_sym, stamper_klass_type) if respond_to?(self.creator_type_attribute.to_sym) && self.polymorphic
          end
        end

        def set_updater_attribute
          return unless self.record_userstamp
          if respond_to?(self.updater_attribute.to_sym) && has_stamper? && self.send("#{self.updater_attribute}").blank?
            self.send("#{self.updater_attribute}=".to_sym, self.class.stamper_class.stamper)
            self.send("#{self.updater_type_attribute}=".to_sym, stamper_klass_type) if respond_to?(self.updater_type_attribute.to_sym) && self.polymorphic
          end
        end

        def set_deleter_attribute
          return unless self.record_userstamp
          if respond_to?(self.deleter_attribute.to_sym) && has_stamper? && self.send("#{self.deleter_attribute}").blank?
            self.send("#{self.deleter_attribute}=".to_sym, self.class.stamper_class.stamper)
            self.send("#{self.deleter_type_attribute}=".to_sym, stamper_klass_type) if respond_to?(self.deleter_type_attribute.to_sym) && self.polymorphic
            save unless defined?(Paranoia) # don't save now with Paranoia
          end
        end
        #end private
      end
    end
  end
end

ActiveRecord::Base.send(:include, Ddb::Userstamp::Stampable) if defined?(ActiveRecord)
