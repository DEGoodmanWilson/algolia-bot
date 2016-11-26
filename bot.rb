require 'sinatra/base'
require 'slack-ruby-client'
require 'algoliasearch'

Algolia.init

# Since we're going to create a Slack client object for each team, this helper keeps all of that logic in one place.
def create_slack_client(slack_api_secret)
  Slack.configure do |config|
    config.token = slack_api_secret
    fail 'Missing API token' unless config.token
  end
  Slack::Web::Client.new
end

# This class contains all of the logic for loading, cloning and updating the tutorial message attachments.
class SlackTutorial
  # Store the welcome text for use when sending and updating the tutorial messages
  def self.welcome_text
    "Welcome to Slack! We're so glad you're here.\nGet started by inviting me into a channel to index. I only index public channels."
  end


  # Store the index of each tutorial section in TUTORIAL_JSON for easy reference later
  def self.items
    {reaction: 0, pin: 1, share: 2}
  end

  # Return a new copy of tutorial_json so each user has their own instance
  def self.new
    self.tutorial_json.deep_dup
  end

  # This is a helper function to update the state of tutorial items
  # in the hash shown above. When the user completes an action on the
  # tutorial, the item's icon will be set to a green checkmark and
  # the item's border color will be set to blue
  def self.update_item(team_id, user_id, item_index)
    # Update the tutorial section by replacing the empty checkbox with the green
    # checkbox and updating the section's color to show that it's completed.
    tutorial_item = $teams[team_id][user_id][:tutorial_content][item_index]
    tutorial_item[:text].sub!(':white_large_square:', ':white_check_mark:')
    tutorial_item[:color] = '#439FE0'
  end
end

# This class contains all of the webserver logic for processing incoming requests from Slack.
class API < Sinatra::Base
  # This is the endpoint Slack will post Event data to.
  post '/events' do
    # Extract the Event payload from the request and parse the JSON
    request_data = JSON.parse(request.body.read)
    # Check the verification token provided with the requat to make sure it matches the verification token in
    # your app's setting to confirm that the request came from Slack.
    unless SLACK_CONFIG[:slack_verification_token] == request_data['token']
      halt 403, "Invalid Slack verification token received: #{request_data['token']}"
    end

    case request_data['type']
      # When you enter your Events webhook URL into your app's Event Subscription settings, Slack verifies the
      # URL's authenticity by sending a challenge token to your endpoint, expecting your app to echo it back.
      # More info: https://api.slack.com/events/url_verification
      when 'url_verification'
        request_data['challenge']

      when 'event_callback'
        # Get the Team ID and Event data from the request object
        team_id = request_data['team_id']
        event_data = request_data['event']

        # Events have a "type" attribute included in their payload, allowing you to handle different
        # Event payloads as needed.
        type = event_data['type']
        unless event_data['subtype'].nil?
          type = type + '.' + event_data['subtype']
        end

        case type
          when 'message'
            # Event handler for messages, including Share Message actions
            Events.message(team_id, event_data)
          when 'message.channel_join'
            Events.channel_join(team_id, event_data)
          else
            # In the event we receive an event we didn't expect, we'll log it and move on.
            puts "Unexpected event:\n"
            puts JSON.pretty_generate(request_data)
        end
        # Return HTTP status code 200 so Slack knows we've received the Event
        status 200
    end
  end
end

# This class contains all of the Event handling logic.
class Events
  # You may notice that user and channel IDs may be found in
  # different places depending on the type of event we're receiving.

  # A new user joins the team
  def self.channel_join(team_id, event_data)

    token = $tokens.find({team_id: team_id}).first

    # decide if this user is _us_. If not, ignore it.
    user_id = event_data['user']
    return unless user_id == token['bot_user_id']

    index = Algolia::Index.new(team_id)
    user_client = create_slack_client(token['user_access_token'])

    # we've joined this channel! Let's index it!
    has_more = true
    limit = 5 # TODO I'd like to up this limit, but we have a 3 second window. We should move this into an async task so we can ingest more!
    while has_more && (limit > 0)

      history = user_client.channels_history(channel: event_data['channel'])


      # messages is a JSON array of messages that we can feed more or less directly to Algolia!
      # TODO problem: Algolia doesn't like Hashie::array. We have to make this a regular Ruby Array.
      history_array = Array.new

      history[:messages].each do |message|
        match = Regexp.new('<@'+token['bot_user_id']+'>:? (.*)').match message['text']

        if (message[:user] != token['bot_user_id']) && (message[:subtype].nil?) && (match.nil?) #don't index messages from us! Don't index subtyped messages! Don't index queries made to us!
          message[:objectID] = event_data['channel']+'.'+message[:ts]
          message[:channel] = event_data['channel']
          history_array.push(message)
        end
      end

      index.add_objects(history_array)

      has_more = history['has_more']
      limit = limit - 1
    end

  end

  def self.message(team_id, event_data)

    token = $tokens.find({team_id: team_id}).first
    user_id = event_data['user']


    # Don't process messages sent from our bot user
    return if user_id == token['bot_user_id']

    index = Algolia::Index.new(team_id)
    # TODO would be nice not to have to set the settings every time
    index.set_settings('searchableAttributes' => ['text', 'attachments.text'], 'customRanking' => ['desc(ts)'])

    client = create_slack_client(token['bot_access_token'])

    # If this _is_ a message to us, don't index it, but act upon it

    match = Regexp.new('<@'+token['bot_user_id']+'>:? (.*)').match event_data['text']
    unless match.nil?
      res = index.search(match[1], {'attributesToRetrieve' => ['channel', 'ts', 'user', 'text'], 'hitsPerPage' => 5})

      # Now, let's set up a response that looks like this:
      # https://api.slack.com/docs/messages/builder?msg=%7B%22text%22%3A%22Here%20are%20some%20results%20I%20found%22%2C%22unfurl_links%22%3Afalse%2C%22unfurl_media%22%3Afalse%2C%22attachments%22%3A%5B%7B%22color%22%3A%22%2336a64f%22%2C%22author_name%22%3A%22Don%20Goodman-Wilson%22%2C%22title%22%3A%22General%22%2C%22title_link%22%3A%22http%3A%2F%2Farchive%20link%22%2C%22text%22%3A%22Here%20is%20the%20original%20text%20discovered%22%2C%22ts%22%3A123456789%7D%2C%7B%22text%22%3A%22%22%2C%22footer%22%3A%22Powered%20by%20Algolia%22%2C%22footer_icon%22%3A%22https%3A%2F%2Fwww.algolia.com%2Fstatic_assets%2Fimages%2Fpress%2Fdownloads%2Falgolia-mark-blue.png%22%2C%22ts%22%3A123456789%7D%5D%7D

      if res['hits'].nil? or (res['hits'].size == 0)
        # not hits to return :(
        client.chat_postMessage(
            text: "I am sorry to say that I found no hits for \"#{match[1]}\"",
            channel: event_data['channel'],
            attachments: [{
                              'text': '',
                              'footer': 'Powered by Aloglia',
                              'footer_icon': 'https://www.algolia.com/static_assets/images/press/downloads/algolia-mark-blue.png'
                          }]
        )

      else
        # we have hits to return!
        attachments = Array.new

        res['hits'].each do |hit|
          # this is super ineffecient without cacheing. It's OK. We can optimize this later
          channel = client.channels_info(channel: hit['channel'])
          user = {'user': {'real_name': 'bot'}}
          user = client.users_info(user: hit['user']) unless hit['user'].nil?
          team_info = client.auth_test()

          team_url = team_info[:url]

          result = {}
          result[:color] = '#005500' # would be cool to color this based on result quality
          result[:author_name] = user[:user][:real_name]
          result[:title] = '#' + channel[:channel][:name]
          result[:title_link] = "#{team_url}archives/#{channel[:channel][:name]}/p#{hit['ts'].sub('.', '')}"
          result[:text] = hit['text']
          result[:ts] = hit['ts'].split('.')[0]
          attachments.push(result)
        end

        # and one more for the credits
        attachments.push({
                             'text': '',
                             'footer': 'Powered by Aloglia',
                             'footer_icon': 'https://www.algolia.com/static_assets/images/press/downloads/algolia-mark-blue.png'
                         })

        client.chat_postMessage(
            text: 'Here are some results I found',
            channel: event_data['channel'],
            unfurl_links: false,
            unfurl_media: false,
            attachments: attachments
        )

      end

      return #short circuit so we don't index this message
    end

    # If this wasn't a request to us, then index this message too!
    message = event_data
    message[:objectID] = message[:channel]+'.'+message[:ts]

    index.add_objects([message])
  end
end
