# Copyright 2017 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "concurrent"
require "google/cloud/spanner/errors"
require "google/cloud/spanner/session"
# require 'debug/open'

module Google
  module Cloud
    module Spanner
      ##
      # @private
      #
      # # Pool
      #
      # Implements a pool for managing and reusing
      # {Google::Cloud::Spanner::Session} instances.
      #
      class Pool
        attr_accessor :all_sessions
        ## Obect of type [Set<String>]
        attr_accessor :checked_out_sessions

        def initialize client, min: 10, max: 100, keepalive: 1800,
                       fail: true, threads: nil
          @client = client
          @min = min
          @max = max
          @keepalive = keepalive
          @fail = fail
          @threads = threads || [2, Concurrent.processor_count * 2].max

          @mutex = Mutex.new
          @resource = ConditionVariable.new

          # initialize pool and availability stack
          init
        end

        def with_session
          session = checkout_session
          begin
            yield session
          ensure
            checkin_session session
          end
        end

        def checkout_session
          action = nil
          @mutex.synchronize do
            loop do
              raise ClientClosedError if @closed

              # Use LIFO to ensure sessions are used from backend caches, which
              # will reduce the read / write latencies on user requests.
              read_session = @all_sessions.pop # LIFO
              if read_session
                checked_out_sessions << read_session.session_id
                return read_session
              end

              if can_allocate_more_sessions?
                action = :new
                break
              end

              raise SessionLimitError if @fail

              @resource.wait @mutex
            end
          end

          session = new_session!
          if action == :new
            @mutex.synchronize do
              @all_sessions.pop
              checked_out_sessions << session.session_id
              return session
            end
          end
        end

        def checkin_session session
          @mutex.synchronize do
            unless checked_out_sessions.include? session.session_id
              raise ArgumentError, "Cannot checkin session"
            end

            @all_sessions.push session
            checked_out_sessions.delete session.session_id

            @resource.signal
          end

          nil
        end

        def with_transaction
          tx = checkout_transaction
          begin
            yield tx
          ensure
            future do
              # Create and checkin a new transaction
              tx = tx.session.create_transaction
              checkin_transaction tx
            end
          end
        end

        def checkout_transaction
          action = nil
          @mutex.synchronize do
            loop do
              raise ClientClosedError if @closed

              read_session = @all_sessions.pop
              if read_session
                action = read_session
                break
              end

              if can_allocate_more_sessions?
                action = :new
                break
              end

              raise SessionLimitError if @fail

              @resource.wait @mutex
            end
          end
          if action.is_a? Google::Cloud::Spanner::Session
            return action.create_transaction
          end
          return new_transaction! if action == :new
        end

        def checkin_transaction txn
          @mutex.synchronize do
            unless @all_sessions.include? txn.session
              raise ArgumentError, "Cannot checkin session"
            end

            @all_sessions.push txn.session

            @resource.signal
          end

          nil
        end

        def reset
          close
          init

          @mutex.synchronize do
            @closed = false
          end

          true
        end

        def close
          shutdown
          @thread_pool.wait_for_termination

          true
        end

        def keepalive_or_release!
          to_keepalive = []
          to_release = []

          @mutex.synchronize do
            available_count = @all_sessions.count
            release_count = @min - available_count
            release_count = 0 if release_count.negative?

            to_keepalive += @all_sessions.select do |x|
              x.idle_since? @keepalive
            end

            # Remove a random portion of the sessions and transactions
            to_release = to_keepalive.sample release_count
            to_keepalive -= to_release

            # Remove those to be released from circulation
            @all_sessions -= to_release.map(&:session)
          end

          to_release.each { |x| future { x.release! } }
          to_keepalive.each { |x| future { x.keepalive! } }
        end

        private

        def init
          # init the thread pool
          @thread_pool = Concurrent::ThreadPoolExecutor.new \
            max_threads: @threads
          # init the stacks
          @new_sessions_in_process = 0
          # init the keepalive task
          create_keepalive_task!
          # init session stack
          @all_sessions = @client.batch_create_new_sessions @min
          @checked_out_sessions = Set.new
        end

        def shutdown
          @mutex.synchronize do
            @closed = true
          end
          @keepalive_task.shutdown
          # Unblock all waiting threads
          @resource.broadcast
          # Delete all sessions
          @mutex.synchronize do
            @all_sessions.each { |s| future { s.release! } }
            @all_sessions = []
            @checked_out_sessions = Set.new
          end
          # shutdown existing thread pool
          @thread_pool.shutdown
        end

        def new_session!
          @mutex.synchronize do
            @new_sessions_in_process += 1
          end

          begin
            session = @client.create_new_session
          rescue StandardError => e
            @mutex.synchronize do
              @new_sessions_in_process -= 1
            end
            raise e
          end

          @mutex.synchronize do
            @new_sessions_in_process -= 1
            @all_sessions << session
          end

          session
        end

        def new_transaction!
          new_session!.create_transaction
        end

        def can_allocate_more_sessions?
          # This is expected to be called from within a synchronize block
          all_sessions.size + @new_sessions_in_process < @max
        end

        def create_keepalive_task!
          @keepalive_task = Concurrent::TimerTask.new execution_interval: 300 do
            keepalive_or_release!
          end
          @keepalive_task.execute
        end

        def future &block
          Concurrent::Future.new(executor: @thread_pool, &block).execute
        end
      end
    end
  end
end
