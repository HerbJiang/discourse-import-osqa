############################################################
#### IMPORT OSQA to Discourse
####
#### originally created for facebook by Sander Datema (info@sanderdatema.nl)
#### forked by Claus F. Strasburger ( http://about.me/cfstras )
####
#### version 0.1
############################################################

############################################################
#### Description
############################################################
#
# This rake task will import all posts and comments of a
# OSQA Forum into Discourse.
#
############################################################
#### Prerequisits
############################################################
#
# - Add this to your Gemfile:
#   gem 'mysql2', require: false
# - Edit the configuration file config/import_osqa.yml

############################################################
#### The Rake Task
############################################################

require 'mysql2'

desc "Import posts and comments from a OSQA Forum"
task "import:osqa" => 'environment' do
  # Import configuration file
  @config = YAML.load_file('config/import_osqa.yml')
  TEST_MODE = @config['test_mode']
  DC_ADMIN = @config['discourse_admin_email']
  DC_ADMIN = nil
  MARKDOWN_LINEBREAKS = true
  DEFAULT_CATEGORY_NAME = 'XXXXXX'

  if TEST_MODE then puts "\n*** Running in TEST mode. No changes to Discourse database are made\n".yellow end

  # Some checks
  # Exit rake task if admin user doesn't exist
  if Discourse.system_user.nil?
    unless dc_user_exists(DC_ADMIN_EMAIL) then
      puts "\nERROR: The admin user email #{DC_ADMIN_EMAIL} does not exist".red
      exit_script
    else
      DC_ADMIN = dc_get_user(DC_ADMIN_EMAIL)
    end
  else
    DC_ADMIN = Discourse.system_user
  end

  begin
    # ask for markdown setting

    input = ''
    puts "Do you want to enable traditional markdown-linebreaks? (linebreaks are ignored unless the line ends with two spaces)"
    print "y/N? >"
    input = STDIN.gets.chomp
    MARKDOWN_LINEBREAKS = ( /y(es)?/i.match(input) or input.empty? )

    puts "Using markdown linebreaks: "+MARKDOWN_LINEBREAKS.to_s

    sql_connect

    sql_fetch_users

    if TEST_MODE then

      sql_fetch_posts

      begin
        require 'irb'
        ARGV.clear
        IRB.start
      rescue :IRB_EXIT
      end
      
      exit_script # We're done
    else
      # Backup Site Settings
      dc_backup_site_settings
      # Then set the temporary Site Settings we need
      dc_set_temporary_site_settings
      # Create users in Discourse
      create_users

      # Import posts into Discourse
      sql_fetch_posts

      # Restore Site Settings
      dc_restore_site_settings
    end
  ensure
    @sql.close if @sql
  end
  puts "\n*** DONE".green
  # DONE!
end


############################################################
#### Methods
############################################################

def sql_connect
  begin
    @sql = Mysql2::Client.new(:host => @config['sql_server'], :username => @config['sql_user'],
      :password => @config['sql_password'], :database => @config['sql_database'])
  rescue Mysql2::Error => e
    puts "\nERROR: Connection to Database failed\n#{e.message}".red
    exit_script
  end

  puts "\nConnected to SQL DB".green
end

def sql_fetch_posts(*parse)
  @post_count = @offset = 0
  @osqa_posts ||= [] # Initialize

  # Fetch OSQA posts in batches and download writer/user info
  loop do
    query = "SELECT
		fn.id AS id,
		fn.title AS title,
		fn.body AS body,
		fn.added_at AS added_at,
		fn.last_activity_at AS last_activity_at,
		fn.author_id,
		u.username,
		u.email,
		fn.parent_id,
		fn.tagnames AS tags,
		fn.node_type AS node_type,
		fn.discourse_id AS discourse_id
		FROM forum_node fn
		JOIN auth_user u ON fn.author_id=u.id
		WHERE fn.discourse_id='0'
		ORDER BY node_type DESC,id ASC
      LIMIT #{@offset.to_s},5000;"
		
    puts query.yellow if @offset == 0
    result = @sql.query query
    
    count = 0
    # Add the results of this batch to the rest of the imported posts
    result.each do |post|
      @osqa_posts << post
      count += 1
    end
    
    puts "Batch ".green + ((@offset%5000) + 1).to_s.green
    @offset += count

    if !TEST_MODE then
      sql_import_posts
      @osqa_posts.clear
    end

    break if count == 0 or count < 5000 # No more posts to import
  end

  puts "\nTotal posts: #{@osqa_posts.count.to_s}".green
end

def sql_fetch_users
  @osqa_users ||= [] # Initialize if needed

  offset = 0
  loop do
    count = 0
    query = "SELECT id, username,
      email, last_login, is_active, is_superuser
      FROM auth_user u
      ORDER BY id ASC
      LIMIT #{offset}, 50;"
    puts query.yellow if offset == 0
    users = @sql.query query
    users.each do |user|
      @osqa_users << user
      count += 1
    end
    offset += count
    break if count == 0
  end
  puts "Amount of users: #{@osqa_users.count.to_s}".green
end

def sql_import_posts
  @osqa_posts.each do |osqa_post|
    @post_count += 1

    # Get details of the writer of this post
    user = @osqa_users.find {|k| k['id'] == osqa_post['author_id']}
    
    if user.nil?
      puts "Warning: User (#{osqa_post['author_id']}) {osqa_post['username']} not found in user list!"
    end
    
    # Get the Discourse user of this writer
    dc_user = dc_get_user(user['email'])
    
    # There is no forum_name in osqa, only tags
    # Here we try to find the first category name matches tags of post
    # So this require you to create categories in Discourse first
    category = nil
    tags = osqa_post['tags'].split(' ').each do |tag| 
        if (tag != DEFAULT_CATEGORY_NAME) then
	  category = get_category(tag)
	  if (!category.nil?) then
            puts "Got non-default category [#{category.name.to_s}]".red
            break;
	  end
        end
    end

    if (category.nil?) then
      category = create_category(DEFAULT_CATEGORY_NAME, DC_ADMIN)
    end

    topic_title = sanitize_topic osqa_post['title']
    # Remove new lines and replace with a space
    # topic_title = topic_title.gsub( /\n/m, " " )
    
    # if there is a discourse id in the post field then that means it has already been imported.
    if osqa_post['discourse_id'] != 0 then
      puts "osqa id [".green + osqa_post['id'].to_s.green + "] skipped, discourse id ".green + osqa_post['discourse_id'].to_s.green
      next
    end

    # are we creating a new topic?    
    topic = nil
    is_new_topic = osqa_post['node_type'].to_s == 'question'

    if is_new_topic then
      topic = osqa_post
      # puts "We got question as topic #{topic_title} / #{osqa_post['id']}"
    else
      if osqa_post['parent_id'].nil? then
        puts "The osaq answer #{osqa_post['id']} [#{topic_title}] has no parent_id, skip it!".red
        next
      end
      puts "We got answer [#{topic_title}], osqa parent_id:#{osqa_post['parent_id']}"
      topics = @sql.query "SELECT id, discourse_id, title
                          FROM forum_node
                          WHERE id = #{osqa_post['parent_id']}"
      topic = topics.first
      puts "Finding the topic osqa id[#{osqa_post['parent_id']}] for post osqa #{osqa_post['id']}"
      if topic.nil? || topic['discourse_id'] == 0 then
        puts "Topic ##{osqa_post['parent_id']} not crated before importing posts".red
	next
      else
        real_topic = get_topic(topic['discourse_id'])
        if (real_topic.nil?) then
           # Actually I encounter some issues that Topic created before but is gone later, dunno why(no error), So I add one more confirmation here.
           puts "Topic ##{osqa_post['parent_id']} failed to created, no reason! before importing posts".red
	   next
        end
      end
    end

    text = sanitize_text osqa_post['body']
    
    # create!
    post_creator = nil
    if is_new_topic
      print "\nCreating topic ".yellow + topic_title +
        " (#{Time.at(osqa_post['added_at'])}) in category ".yellow +
        "#{category.name}"
      post_creator = PostCreator.new(
        dc_user,
        skip_validations: true,
        raw: text,
        title: sanitize_topic(topic_title),
        archetype: 'regular',
        category: category.name,
        created_at: Time.at(osqa_post['added_at']),
        updated_at: Time.at(osqa_post['last_activity_at']))

      # for a new topic: also clear mail deliveries
      ActionMailer::Base.deliveries = []
    else
      print "using topic #".yellow + "osqa id:" + topic['id'].to_s.yellow + " discourse id:" + topic['discourse_id'].to_s.yellow + "[" + topic['title'] + "]"

      post_creator = PostCreator.new(
        dc_user,
        skip_validations: true,
        raw: text,
        topic_id: topic['discourse_id'],
        created_at: Time.at(osqa_post['added_at']),
        updated_at: Time.at(osqa_post['last_activity_at']))
    end
    post = nil
    begin
      post = post_creator.create
    rescue Exception => e
      puts "Error #{e} on osqa post #{osqa_post['id']}:\n#{text}"
      puts "--"
      puts e.inspect
      puts e.backtrace
      abort
    end
    # Everything set, save the topic
    if post_creator.errors.present? # Skip if not valid for some reason
      puts "\nContents of topic from post #{osqa_post['id']} failed to ".red+
               "import: #{post_creator.errors.full_messages}".red
    else
      post_serializer = PostSerializer.new(post, scope: true, root: false)
      post_serializer.topic_slug = post.topic.slug if post.topic.present?
      post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)

      discourse_postid_noted = @sql.query "UPDATE forum_node
        SET discourse_id = #{post.id}
        WHERE id = '#{osqa_post['id']}'"

      puts "\nTopic #{osqa_post['id']} created".green if is_new_topic
    end

    puts "\n[".green + @post_count.to_s.green + "] added".green
    puts "  " + text.to_s
  end
end


# Returns the Discourse category where imported posts will go
def create_category(name, owner)
  if Category.where('lower(name) = ?', name.downcase).empty? then
    puts "\nCreating category '#{name}'".yellow
    Category.create!(name: name, user_id: owner.id)
  else
    # puts "Category '#{name}'".yellow
    Category.where('lower(name) = ?', name.downcase).first
  end
end

def get_category(name)
  Category.where('lower(name) = ?', name.downcase).first
end

def get_topic(id)
  Topic.where('id = ?', id).first
end

# Create a Discourse user with OSQA info unless it already exists
def create_users
  @osqa_users.each do |osqa_user|
    # Setup Discourse username
    dc_username = osqa_username_to_dc(osqa_user['username'])
    
    dc_email = osqa_user['email']
    # Create email address for user
    if dc_email.nil? or dc_email.empty? then
      dc_email = dc_username + "@has.no.email"
    end

    approved = osqa_user['is_active'] == 1
    approved_by_id =  if approved
                        DC_ADMIN.id
                      else
                        nil
                      end

    # Just set every user w/o admin privileges
    admin = false
#    If you want the admin in osqa is also the admin in discourse, use following code
#    admin = if osqa_user['is_superuser'] == 1
#            true
#              else
#            false
#              end

    # Create user if it doesn't exist
    if User.where('email = ?', dc_email).empty? then

      begin
        dc_user = User.create!(username: dc_username,
                               name: osqa_user['username'],
                               email: dc_email,
                               active: false,
                               approved: approved,
                               approved_by_id: approved_by_id,
                               admin: admin,
                               last_seen_at: Time.at(osqa_user['last_login']))
      rescue Exception => e
        puts "Error #{e} on user #{dc_username} <#{dc_email}>"
        puts "--"
        puts e.inspect
        puts e.backtrace
        abort
      end
      #TODO: add authentication info
      puts "User (#{osqa_user['id']}) #{osqa_user['username']} (#{dc_username} / #{dc_email}) created".green
    else
      puts "User (#{osqa_user['id']}) #{osqa_user['username']} (#{dc_username} / #{dc_email}) found".green
    end
  end
end

def sanitize_topic(text)
  CGI.unescapeHTML(text)
end

def sanitize_text(text)
  text = CGI.unescapeHTML(text)

  # -- Pre process the text
  # screaming
  unless seems_quiet?(text)
    text = '<capslock> ' + text.downcase
  end

  unless seems_pronounceable?(text)
    text = "<symbols>\n" + text
  end

  # replace smilies
  text.gsub! /<!--.*--><img src=".*" alt="(.*)" title=".*" \/><!--.*-->/i, ' \1 '

  # remove tag IDs
  text.gsub! /\[(\/?[a-zA-Z]+(=("[^"]*?"|[^\]]*?))?):[a-z0-9]+\]/, '[\1]'

  # completely remove youtube, soundcloud and url tags as those links are oneboxed
  # color is not supported
  text.gsub! /\[(youtube|soundcloud|url|img|color|str)\](.*?)\[\/\1\]/m, "\n"+'\2'+"\n"

  # yt tags are custom for our forum
  text.gsub! /\[yt\]([a-zA-Z0-9_-]*)\[\/yt\]/i, ' http://youtu.be/\1 '
  text.gsub! /\[youtubefull\](.*)\[\/youtubefull\]/i, ' http://youtu.be/\1 '

  # add any tag aliases here
  text.gsub! /\[spoiler(.*)\](.*)\[\/spoiler\]/i, '[spoiler]\2[/spoiler]'
  text.gsub! /\[inlinespoiler\](.*)\[\/inlinespoiler\]/i, '[spoiler]\1[/spoiler]'

  # size tags
  # discourse likes numbers from 4-40 (pt), osqa uses 20 to 200 (percent)
  # [size=85:az5et819]dump dump[/size:az5et819]
  text.gsub! /\[size=(\d+)(%?)\]/ do |match|
    pt = $1.to_i / 100 * 14 # 14 is the default text size
    pt = 40 if pt > 40
    pt = 4 if pt < 4

    "[size=#{pt}]"
  end

  #RubyBBCode.disable_validation
  
  # -- Now use ruby-bbcode-to-md gem
  #text.bbcode_to_md!(false)

  # -- Post processing..

  # bbcode->md gem assumes single newline md
  # convert newlines to markdown syntax
  text.gsub! /([^\n])\n/, '\1  '+"\n" if MARKDOWN_LINEBREAKS
    
  # convert code blocks to markdown syntax
  text.gsub! /\[code\](.*?)\[\/code\]/m do |match|
    "\n    " + $1.gsub(/(  )?\n(.)/, "\n"+'    \2') + "\n"
  end

  text
end


### Methods stolen from lib/text_sentinel.rb
def seems_quiet?(text)
  # We don't allow all upper case content in english
  not((text =~ /[A-Z]+/) && !(text =~ /[^[:ascii:]]/) && (text == text.upcase))
end
def seems_pronounceable?(text)
  # At least some non-symbol characters
  # (We don't have a comprehensive list of symbols, but this will eliminate some noise)
  text.gsub(symbols_regex, '').size > 0
end
def symbols_regex
  /[\ -\/\[-\`\:-\@\{-\~]/m
end
###

# Backup site settings
def dc_backup_site_settings
  s = {}
  #Discourse::Application.configure do
  #  s['mailer'] = config.action_mailer.perform_deliveries
  #  s['method'] = config.action_mailer.delivery_method
  #  s['errors'] = config.action_mailer.raise_delivery_errors = false
  #end
  
  s['unique_posts_mins'] = SiteSetting.unique_posts_mins
  s['rate_limit_create_topic'] = SiteSetting.rate_limit_create_topic
  s['rate_limit_create_post'] = SiteSetting.rate_limit_create_post
  s['max_topics_per_day'] = SiteSetting.max_topics_per_day
  s['title_min_entropy'] = SiteSetting.title_min_entropy
  s['body_min_entropy'] = SiteSetting.body_min_entropy
  
  s['min_post_length'] = SiteSetting.min_post_length
  s['newuser_spam_host_threshold'] = SiteSetting.newuser_spam_host_threshold
  s['min_topic_title_length'] = SiteSetting.min_topic_title_length
  s['newuser_max_links'] = SiteSetting.newuser_max_links
  s['newuser_max_images'] = SiteSetting.newuser_max_images
  s['max_word_length'] = SiteSetting.max_word_length
  s['email_time_window_mins'] = SiteSetting.email_time_window_mins
  s['max_topic_title_length'] = SiteSetting.max_topic_title_length
  #s['abc'] = SiteSetting.abc
  
  @site_settings = s
end

# Restore site settings
def dc_restore_site_settings
  s = @site_settings
  #Discourse::Application.configure do
  #  config.action_mailer.perform_deliveries = s['mailer']
  #  config.action_mailer.delivery_method = s['method']
  #  config.action_mailer.raise_delivery_errors = s['errors']
  #end


  RateLimiter.enable

  SiteSetting.send("unique_posts_mins=", s['unique_posts_mins'])
  SiteSetting.send("rate_limit_create_topic=", s['rate_limit_create_topic'])
  SiteSetting.send("rate_limit_create_post=", s['rate_limit_create_post'])
  SiteSetting.send("max_topics_per_day=", s['max_topics_per_day'])
  SiteSetting.send("title_min_entropy=", s['title_min_entropy'])
  SiteSetting.send("body_min_entropy=", s['body_min_entropy'])
    
  SiteSetting.send("min_post_length=", s['min_post_length'])
  SiteSetting.send("newuser_spam_host_threshold=", s['newuser_spam_host_threshold'])
  SiteSetting.send("min_topic_title_length=", s['min_topic_title_length'])
  SiteSetting.send("newuser_max_links=", s['newuser_max_links'])
  SiteSetting.send("newuser_max_images=", s['newuser_max_images'])
  SiteSetting.send("max_word_length=", s['max_word_length'])
  SiteSetting.send("email_time_window_mins=", s['email_time_window_mins'])
  SiteSetting.send("max_topic_title_length=", s['max_topic_title_length'])
  #SiteSetting.send("abc=", s['abc'])
end

# Set temporary site settings needed for this rake task
def dc_set_temporary_site_settings
  # don't backup this first one
  SiteSetting.send("traditional_markdown_linebreaks=", MARKDOWN_LINEBREAKS)

  RateLimiter.disable

  SiteSetting.send("unique_posts_mins=", 0)
  SiteSetting.send("flag_sockpuppets=", 0)
  SiteSetting.send("rate_limit_create_topic=", 0)
  SiteSetting.send("rate_limit_create_post=", 0)
  SiteSetting.send("max_topics_per_day=", 100000)
  SiteSetting.send("title_min_entropy=", 1)
  SiteSetting.send("body_min_entropy=", 1)
  
  SiteSetting.send("min_post_length=", 1) # never set this to 0
  SiteSetting.send("newuser_spam_host_threshold=", 10000)
  SiteSetting.send("min_topic_title_length=", 2)
  SiteSetting.send("max_topic_title_length=", 512)
  SiteSetting.send("newuser_max_links=", 10000)
  SiteSetting.send("newuser_max_images=", 10000)
  SiteSetting.send("max_word_length=", 5000)
  SiteSetting.send("email_time_window_mins=", 1)
  #SiteSetting.send("abc=", 0)
end

# Check if user exists
# For some really weird reason this method returns the opposite value
# So if it did find the user, the result is false
def dc_user_exists(email)
  User.where('email = ?', email).exists?
end

def dc_get_user_id(email)
  User.where('email = ?', email).first.id
end

def dc_get_user(email)
  User.where('email = ?', email).first
end

# Returns current unix time
def current_unix_time
  Time.now.to_i
end

def unix_to_human_time(unix_time)
  Time.at(unix_time).strftime("%d/%m/%Y %H:%M")
end

# Exit the script
def exit_script
  puts "\nScript will now exit\n".yellow
  abort
end

def osqa_username_to_dc(name)
  # Create username from full name, only letters and numbers
  username = name.tr('^A-Za-z0-9', '').downcase
  # Maximum length of a Discourse username is 15 characters
  username = username[0,15]
end

# Add colors to class String
class String
  def red
    colorize(self, 31);
  end

  def green
    colorize(self, 32);
  end

  def yellow
    colorize(self, 33);
  end

  def blue
    colorize(self, 34);
  end

  def colorize(text, color_code)
    "\033[#{color_code}m#{text}\033[0m"
  end
end

# Calculate percentage
class Numeric
  def percent_of(n)
    self.to_f / n.to_f * 100.0
  end
end
