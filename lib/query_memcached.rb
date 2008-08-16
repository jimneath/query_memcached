require 'digest/md5'

unless defined?(::Rails.cache) || ::Rails.cache.class.is_a?(ActiveSupport::Cache::MemCacheStore)
  warning = "[Query memcached WARNING] ::Rails.cache is not defined or cache engine is not mem_cache_store"
  ActiveRecord::Base.logger.error warning
  raise warning
end 

module ActiveRecord
    
  class Base

    # table_names is a special attribute that contains a regular expression with all the tables of the application 
    # Its main purpose  is to detect all the tables that a query affects.
    # It is build in a special way: 
    #   - first we get all the tables
    #   - then we sort them from major to minor lenght, in order to detect tables which name is a composition of two
    #     names, i.e, posts, comments and comments_posts. It is for make easier the regular expression
    #   - and finally, the regular expression is built
    cattr_accessor :table_names
    
    self.table_names = []
    ActiveRecord::Base.connection.execute('show tables').each { |t| self.table_names << t.first }    
    self.table_names = /#{self.table_names.sort{ |a,b| b.length <=> a.length }.join('|')}/i
    
    def create_or_update_with_clean_query_cache(*args)
      self.class.increase_version!
      create_or_update_without_clean_query_cache(*args)
    end

    alias_method_chain :create_or_update, :clean_query_cache
    
    def destroy_with_clean_query_cache(*args)
      self.class.increase_version!
      destroy_without_clean_query_cache(*args)
    end

    alias_method_chain :destroy, :clean_query_cache
            
    class << self
      def cache_version_key      
        "version/#{self.table_name}" 
      end
      
      def delete_all_with_clean_query_cache(*args)
        increase_version!
        delete_all_without_clean_query_cache(*args)
      end

      alias_method_chain :delete_all, :clean_query_cache      

      def update_all_with_clean_query_cache(*args)
        increase_version!
        update_all_without_clean_query_cache(*args)
      end

      alias_method_chain :update_all, :clean_query_cache      
      
      def increase_version!
        # Increment the class version key number
        key = cache_version_key
        if r = ::Rails.cache.read(key).to_i
          ::Rails.cache.write(key,(r+1%10000000))
        else
          ::Rails.cache.write(key,1)
        end
      end
      
    end    

  end  
end

module ActiveRecord
  module ConnectionAdapters # :nodoc:
    module QueryCache
      
      class << self
        def included(base)
          base.class_eval do
            attr_accessor :query_cache_enabled
            alias_method_chain :columns, :query_cache
            alias_method_chain :select_all, :query_cache
          end

          dirties_query_cache base, :insert, :update, :delete
        end

        def dirties_query_cache(base, *method_names)
          method_names.each do |method_name|
            base.class_eval <<-end_code, __FILE__, __LINE__
              def #{method_name}_with_query_dirty(*args)
                clear_query_cache if @query_cache_enabled
                #{method_name}_without_query_dirty(*args)
              end

              alias_method_chain :#{method_name}, :query_dirty
            end_code
          end
        end
      end

      # Enable the query cache within the block
      def cache
        old, @query_cache_enabled = @query_cache_enabled, true
        @query_cache ||= {}
        @cache_version ||= {}
        yield
      ensure
        clear_query_cache
        @query_cache_enabled = old
      end

      # Disable the query cache within the block.
      def uncached
        old, @query_cache_enabled = @query_cache_enabled, false
        yield
      ensure
        @query_cache_enabled = old
      end

      # Clears the query cache.
      #
      # One reason you may wish to call this method explicitly is between queries
      # that ask the database to randomize results. Otherwise the cache would see
      # the same SQL query and repeatedly return the same result each time, silently
      # undermining the randomness you were expecting.
      def clear_query_cache
        @query_cache.clear if @query_cache
        @cache_version.clear if @cache_version
      end

      def select_all_with_query_cache(*args)
        if @query_cache_enabled          
          cache_sql(args.first) { select_all_without_query_cache(*args) }
        else
          select_all_without_query_cache(*args)
        end
      end

      def columns_with_query_cache(*args)
        if @query_cache_enabled
          @query_cache["SHOW FIELDS FROM #{args.first}"] ||= columns_without_query_cache(*args)
        else
          columns_without_query_cache(*args)
        end
      end

      private

        def cache_sql(sql)
          # priority order:
          #  - if in @query_cache (memory of local app server) we prefer this
          #  - else if exists in Memcached we prefer that 
          #  - else perform query in database and save memory caches
          result =
            if @query_cache.has_key?(sql)
              log_info(sql, "CACHE", 0.0)
              @query_cache[sql]
            elsif cached_result = ::Rails.cache.read(query_key(sql))
              log_info(sql, "MEMCACHE", 0.0)
              @query_cache[sql] = cached_result
              cached_result
            else
              query_result = yield
              @query_cache[sql] = query_result
              ::Rails.cache.write(query_key(sql),query_result)
              query_result
            end

          if Array === result
            result.collect { |row| row.dup }
          else
            result.duplicable? ? result.dup : result
          end
        rescue
          yield
        end
        
        # Transforms a sql query into a valid key for Memcache
        def query_key(sql)
          table_names, clean_query = extract_table_names(sql)
          # version_number is the sum of the global version number and all the version number of each table
          version_number = get_cache_version
          table_names.each { |table_name| version_number += get_cache_version(table_name) }

          # check if the result_key is short enough for memcache key length limit (250 char)
          result_key = "#{version_number}_#{clean_query}"          
          result_key = "#{version_number}_#{Digest::MD5.hexdigest(clean_query)}" if result_key.to_s.length + ::Rails.cache.instance_variable_get(:@data).namespace.length + 1 >= 250
          result_key
        end

        # Returns the cache version of a table_name. If table_name is empty its the global version
        # 
        # We prefer to search for this key first in memory and then in Memcache
        def get_cache_version(table_name = nil)
          key_class_version = "version"
          key_class_version << "/#{table_name}" if table_name
          if @cache_version && @cache_version[key_class_version]
            @cache_version[key_class_version]
          elsif version = ::Rails.cache.read(key_class_version)
            @cache_version[key_class_version] = version if @cache_version
            version
          else 
            @cache_version[key_class_version] = 0 if @cache_version
            ::Rails.cache.write(key_class_version, 0)
            0
          end
        end

        # Given a sql query this method extract all the table names of the database affected by the query
        # thanks to the regular expression we have generated on the load of the plugin
        def extract_table_names(sql)
          sql.gsub!(/`/,'')          
          clean_query = sql.gsub(/[ ]+/,'_').gsub(/`/,'').gsub(/\t/,'').gsub(/\n/,'').gsub(/\r/,'')
          table_names = sql.scan(ActiveRecord::Base.table_names).map{ |t| t.strip}.uniq
          return table_names, clean_query
        end

    end
  end
end
