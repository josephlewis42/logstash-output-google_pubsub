# Author: Eric Johnson <erjohnso@google.com>
# Date: 2017-12-25
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
require 'logstash/outputs/base'
require 'logstash/namespace'
require 'logstash/outputs/pubsub/client'

#
# === Summary
#
# A LogStash plugin to upload log events to https://cloud.google.com/pubsub/[Google Cloud Pubsub].
# Events are batched and uploaded in the background for the sake of efficiency.
# Message payloads are serialized JSON representations of the events.
#
# === Environment Configuration
#
# To use this plugin, you must create a
# https://developers.google.com/storage/docs/authentication#service_accounts[service account]
# and grant it the publish permission on a topic.
# The topic __must__ exist before you run the plugin.
#
# === Usage
#
# There are two major ways to authenticate to Google Cloud Pubsub:
#
# * autodiscovered
#   https://cloud.google.com/docs/authentication/production[Application Default Credentials]
# * a GCP Service Account JSON file
#
# Example configuration:
#
# [source,ruby]
# ------------------------------------------------------------------------------
# output {
#   google_pubsub {
#     # Required attributes
#     project_id => "my_project"                                      (required)
#     topic => "my_topic"                                             (required)
#
#     # Optional if you're using app default credentials
#     json_key_file => "service_account_key.json"                     (optional)
#
#     # Options for configuring the upload
#     message_count_threshold => 100                                  (optional)
#     delay_threshold_secs => 5                                       (optional)
#     request_byte_threshold => 4096                                  (optional)
#     attributes => {"key" => "value"}                                (optional)
#   }
# }
# ------------------------------------------------------------------------------
#
class LogStash::Outputs::GooglePubsub < LogStash::Outputs::Base
  config_name 'google_pubsub'

  concurrency :shared

  # Google Cloud Project ID (name, not number)
  config :project_id, validate: :string, required: true

  # Google Cloud Pub/Sub Topic. You must create the topic manually.
  config :topic, validate: :string, required: true

  # If logstash is running within Google Compute Engine, the plugin will use
  # GCE's Application Default Credentials. Outside of GCE, you will need to
  # specify a Service Account JSON key file.
  config :json_key_file, validate: :path, required: false

  # Send the batch once this delay has passed, from the time the first message
  # is queued. (> 0, default: 5)
  config :delay_threshold_secs, validate: :number, required: true, default: 5

  # Once this many messages are queued, send all the messages in a single call,
  # even if the delay threshold hasn't elapsed yet. (< 1000, default: 100)
  config :message_count_threshold, validate: :number, required: true, default: 100

  # Once the number of bytes in the batched request reaches this threshold,
  # send all of the messages in a single call, even if neither the delay or
  # message count thresholds have been exceeded yet.
  #
  # This includes full message payload size, including any attributes set.
  #
  # Default: 1MB
  config :request_byte_threshold, validate: :number, required: true, default: 1_000_000

  # Attributes to add to the message in key: value formats.
  # Keys and values MUST be strings.
  config :attributes, validate: :hash, required: true, default: {}

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, 'plain'

  def register
    @logger.info("Registering Google PubSub Output plugin: #{full_topic}")

    batch_settings = LogStash::Outputs::Pubsub::Client.build_batch_settings(
      @request_byte_threshold,
      @delay_threshold_secs,
      @message_count_threshold
    )

    @pubsub = LogStash::Outputs::Pubsub::Client.new(
        @json_key_file,
        full_topic,
        batch_settings,
        @logger
    )

    # Test that the attributes don't cause errors when they're set.
    begin
      @pubsub.build_message '', @attributes
    rescue TypeError => e
      message ='Make sure the attributes are string:string pairs'
      @logger.info(message, error: e, attributes: @attributes)
      raise message
    end
  end

  def receive(event)
    message = event.to_json
    @logger.info("Sending message #{message}")

    @pubsub.publish_message message, @attributes
  end

  def stop
    @pubsub.shutdown
  end

  def full_topic
    "projects/#{@project_id}/topics/#{@topic}"
  end
end
