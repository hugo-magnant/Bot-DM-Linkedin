require "capybara"
require "capybara/dsl"
require "selenium-webdriver"
require "net/http"
require "json"
require "uri"
require "dotenv"
Dotenv.load

class LinkedInAutomation
  include Capybara::DSL

  LOCATION_SELECTOR = "div.bPIKubaCZcXXVWwCYCRGqvjSHKFvUoNzpKMthc span.text-body-small.inline.t-black--light.break-words".freeze
  MAX_MESSAGES = 50

  def initialize
    setup_capybara
  end

  def run
    login
    navigate_to_connections
    process_connections
  end

  private

  def setup_capybara
    Capybara.register_driver :selenium do |app|
      Capybara::Selenium::Driver.new(app, browser: :firefox)
    end
    Capybara.current_driver = :selenium
    Capybara.app_host = "https://www.linkedin.com"
  end

  def login
    puts "login"
    visit("/")
    find('button[data-tracking-control-name="ga-cookie.consent.accept.v4"]', wait: 10).click
    find(:css, 'input[name="session_key"]').set(ENV["LINKEDIN_EMAIL"], wait: 5)
    find(:css, 'input[name="session_password"]').set(ENV["LINKEDIN_PASSWORD"], wait: 5)
    find('button[data-id="sign-in-form__submit-btn"]', wait: 30).click
    find("div.feed-identity-module__actor-meta.break-words", wait: 30)
  end

  def navigate_to_connections
    puts "navigate_to_connections"
    visit "https://www.linkedin.com/mynetwork/invite-connect/connections/"
    find("header.mn-connections__header", wait: 10) # Attend jusqu'à 10 secondes pour que le header apparaisse
  end

  def process_connections
    puts "process_connections"
    scroll_and_collect_profiles.each do |href|
      visit_and_message(href)
    end
  end

  def scroll_and_collect_profiles
    puts "scroll_and_collect_profiles"
    all_hrefs = []
    loop do
      execute_script("window.scrollTo(0, document.body.scrollHeight);", wait: 300)
      if has_button?("Afficher plus de résultats", class: "scaffold-finite-scroll__load-button", wait: 300)
        find_button(class: "scaffold-finite-scroll__load-button", wait: 10).click
      else
        break
      end
    end
    all("li.mn-connection-card").each do |connection_card|
      within(connection_card) do
        profile_link = find("a.mn-connection-card__link")[:href]
        all_hrefs << profile_link
      end
    end
    puts all_hrefs.count
    excluded_profiles = []
    File.open("excluded_profiles.txt", "r") do |f|
      f.each_line do |line|
        excluded_profiles << line.strip
      end
    end
    filtered_hrefs = all_hrefs.reject { |href| excluded_profiles.include?(href) }
    puts filtered_hrefs.count
    shuffled_hrefs = filtered_hrefs.shuffle
  end

  def visit_and_message(href)
    puts "visit_and_message"
    max_attempts = 5
    attempt(href, max_attempts)
    find(:xpath, "//button[contains(@aria-label, 'Envoyer un message à')]", wait: 15).click
    if has_css?(".msg-overlay-bubble-header__title", text: "Nouveau message", wait: 5)
      send_message(href)
    else
      handle_failed_message(href)
    end
  end

  def attempt(href, max_attempts, attempts: 0, wait_time: 2)
    puts "attempt"
    visit href
    find("h1.text-heading-xlarge", wait: 10)
  rescue Net::ReadTimeout
    if (attempts += 1) <= max_attempts
      sleep(wait_time)
      attempt(href, max_attempts, attempts: attempts, wait_time: wait_time * 2)
    else
      puts "Failed to visit #{href} after #{max_attempts} attempts."
    end
  end

  def send_message(href)
    puts "send_message"
    location = fetch_location
    first_name = fetch_first_name
    prepare_and_send_message(first_name, location)
    finalize_message(href)
  end

  def fetch_location
    puts "fetch_location"
    find(LOCATION_SELECTOR, wait: 5).text
  end

  def fetch_first_name
    puts "fetch_first_name"
    find(".text-heading-xlarge").text.split(" ").first
  end

  def prepare_and_send_message(first_name, location)
    puts "prepare_and_send_message"
    message = select_message_based_on_location(location, first_name)
    message.each { |line| send_keys(line, :enter, :enter) }
    send_keys(:control, :enter)
  end

  def select_message_based_on_location(location, first_name)
    puts "select_message_based_on_location"
    language_preference = make_request("Ecris moi juste 'en' ou 'fr' suivant la langue la plus adapté à '#{location}'")
    language_preference == "fr" ? message_fr(first_name) : message_en(first_name)
  end

  def message_fr(first_name)
    [
      "Bonjour #{first_name} ! Je suis développeur avec plusieurs projets à mon actif.",
      "Je vous contacte parce que je cherche à développer mon réseau mais aussi parce que je suis à la recherche d’un CDI",
      "Si vous avez une opportunité à me présenter, je serais ravi d'en discuter.",
      "À très vite !",
      "Hugo",
    ]
  end

  def message_en(first_name)
    [
      "Hello #{first_name} ! I'm a developer with several projects under my belt.",
      "I'm reaching out to you because I'm looking to expand my professional network and I'm also on the hunt for a new fulltime opportunity.",
      "If you have any projects or roles that you think would be a good fit for me, I'd love to discuss them further.",
      "Talk to you soon !",
      "Hugo",
    ]
  end

  def make_request(content)
    uri = URI.parse("https://api.openai.com/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.request_uri, {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{ENV["OPENAI_API"]}",
    })

    request.body = JSON.dump({
      "model" => "gpt-4",
      "messages" => [
        {
          "role" => "user",
          "content" => content,
        },
      ],
      "temperature" => 1,
      "max_tokens" => 256,
      "top_p" => 1,
      "frequency_penalty" => 0,
      "presence_penalty" => 0,
    })

    response = http.request(request)
    parsed_response = JSON.parse(response.body)
    extracted_content = parsed_response["choices"][0]["message"]["content"]
    extracted_content
  end

  def finalize_message(href)
    puts "finalize_message"
    send_keys(:escape)
    excluded_profiles << href
    File.open("excluded_profiles.txt", "w") { |f| excluded_profiles.each { |profile| f.puts(profile) } }
  end

  def handle_failed_message(href)
    send_keys(:escape)
    add_href_to_excluded(href)
  end

  def add_href_to_excluded(href)
    File.open("excluded_profiles.txt", "a") do |file|
      file.puts(href)
    end
  end

  def excluded_profiles
    @excluded_profiles ||= File.readlines("excluded_profiles.txt").map(&:strip)
  end
end

bot = LinkedInAutomation.new
bot.run
