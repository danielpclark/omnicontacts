require "omnicontacts/parse_utils"
require "omnicontacts/middleware/oauth2"

module OmniContacts
  module Importer
    class Gmail < Middleware::OAuth2
      include ParseUtils

      attr_reader :auth_host, :authorize_path, :auth_token_path, :scope

      def initialize *args
        super *args
        @auth_host = "accounts.google.com"
        @authorize_path = "/o/oauth2/auth"
        @auth_token_path = "/o/oauth2/token"
        @scope = "https://www.google.com/m8/feeds https://www.googleapis.com/auth/userinfo#email https://www.googleapis.com/auth/userinfo.profile"
        @contacts_host = "www.google.com"
        @contacts_path = "/m8/feeds/contacts/default/full"
        @max_results =  (args[3] && args[3][:max_results]) || 100
        @self_host = "www.googleapis.com"
        @profile_path = "/oauth2/v1/userinfo"
      end

      def fetch_contacts_using_access_token access_token, token_type
        fetch_current_user(access_token, token_type)
        contacts_response = https_get(@contacts_host, @contacts_path, contacts_req_params, contacts_req_headers(access_token, token_type))
        contacts_from_response contacts_response
      end

      def fetch_current_user access_token, token_type
        self_response = https_get(@self_host, @profile_path, contacts_req_params, contacts_req_headers(access_token, token_type))
        user = current_user(self_response, access_token, token_type)
        set_current_user user
      end

      private

      def contacts_req_params
        {'max-results' => @max_results.to_s, 'alt' => 'json'}
      end

      def contacts_req_headers token, token_type
        {"GData-Version" => "3.0", "Authorization" => "#{token_type} #{token}"}
      end

      def contacts_from_response response_as_json
        response = JSON.parse(response_as_json)
        return [] if response['feed'].nil? || response['feed']['entry'].nil?
        contacts = []
        return contacts if response.nil?
        response['feed']['entry'].each do |entry|
          # creating nil fields to keep the fields consistent across other networks

          contact = { :id => nil,
                      :first_name => nil,
                      :middle_name => nil,
                      :last_name => nil,
                      :name => nil,
                      :email => nil,
                      :emails => [],
                      :gender => nil,
                      :birthday => nil,
                      :birthdays => [],
                      :anniversary => nil,
                      :anniversaries => [],
                      :profile_picture=> nil,
                      :messenger_ids => [],
                      :phone => nil,
                      :phones => [],
                      :address_1 => nil,
                      :address_2 => nil,
                      :address_3 => nil,
                      :city => nil,
                      :region => nil,
                      :postcode => nil,
                      :country => nil,
                      :country_abbrev => nil,
                      :addresses => [],
                      :job_title => nil,
                      :company => nil,
                      :nickname => nil,
                      :website => nil,
                      :websites => [],
                      :notes => nil,
                      :relation => nil }
          contact[:id] = entry['id'].try(:[],'$t')
          contact[:first_name] = normalize_name(entry['gd$name'].try(:[],'gd$givenName').try(:[],'$t'))
          contact[:last_name] = normalize_name(entry['gd$name'].try(:[],'gd$familyName').try(:[],'$t'))
          contact[:name] = normalize_name(entry['gd$name'].try(:[],'gd$fullName').try(:[],'$t')) ||
                           full_name(contact[:first_name],contact[:last_name])            
          entry['gd$email'].each do |email|
            *label = email['rel'].try(:split, '#') || email['label']
            contact[:emails] = Array(contact[:emails]) << {
              name: label[-1],
              type: label[-1],
              email: email['address']
            }
          end if entry['gd$email']

          # Support old version
          contact[:email] = contact[:emails].first.try(:[], :email)
          contact[:first_name], contact[:last_name], contact[:name] = email_to_name(contact[:name]) if !contact[:name].nil? && contact[:name].include?('@')
          contact[:first_name], contact[:last_name], contact[:name] = email_to_name(contact[:emails].first[:email]) if contact[:name].nil? && contact[:emails].first.try(:[],:email)
          #format - year-month-date
          contact[:birthday] = birthday(entry['gContact$birthday']['when'])  if entry['gContact$birthday']
          # value is either "male" or "female"
          contact[:gender] = entry['gContact$gender']['value']  if entry['gContact$gender']

          if entry['gContact$relation']
            if entry['gContact$relation'].is_a?(Hash)
              contact[:relation] = entry['gContact$relation']['rel']
            elsif entry['gContact$relation'].is_a?(Array)
              contact[:relation] = entry['gContact$relation'].first['rel']
            end
          end

          entry['gd$structuredPostalAddress'].each do |address|
            *label = address['rel'].try(:split, '#') || address['label']
            new_address = {
              name: label[-1],
              type: label[-1]
            }
            new_address[:address_1] = address['gd$street'].try(:[],'$t') || address['gd$formattedAddress'].try(:[],'$t')
            new_address[:address_1], new_address[:address_2], *new_address[:address_3] = new_address[:address_1].split("\n")
            new_address[:address_3] = ( new_address[:address_3].empty? ? nil : new_address[:address_3].join(', ') )
            new_address[:city] = address['gd$city'].try(:[],'$t')
            new_address[:region] = address['gd$region'].try(:[],'$t')
            new_address[:country] = address['gd$country'].try(:[],'$t') # || address['gd$country'].try(:[],'code') # `code` doesn't seem to be in spec
            new_address[:postcode] = address['gd$postcode'].try(:[],'$t')
            contact[:addresses] = Array(contact[:addresses]) << new_address
          end if entry['gd$structuredPostalAddress']

          # Support old version
          contact[:address_1] = contact[:addresses].first.try(:[],:address_1)
          contact[:address_2] = contact[:addresses].first.try(:[],:address_2)
          contact[:address_3] = contact[:addresses].first.try(:[],:address_3)
          contact[:city] = contact[:addresses].first.try(:[],:city)
          contact[:region] = contact[:addresses].first.try(:[],:region)
          contact[:country] = contact[:addresses].first.try(:[],:country)
          contact[:postcode] = contact[:addresses].first.try(:[],:postcode)

          contact[:phone_numbers] = []
          entry['gd$phoneNumber'].each do |phone|
            *label = phone['rel'].try(:split, '#') || phone['label']
            contact[:phone] = {
              name: label[-1],
              type: label[-1],
              number: phone['$t']
            }
            contact[:phones] = Array(contact[:phones]) << contact[:phone]
            contact[:phone_numbers] = Array(contact[:phone_numbers]) << contact[:phone]
          end if entry['gd$phoneNumber']

          # Support older versions of the gem by keeping singular entries around
          contact[:phone_number] = contact[:phones].first.try(:[],:number)

          if entry['gContact$website']
            entry['gContact$website'].each do |website|
              contact[:website] = website['href']
              contact[:websites] = Array(contact[:websites]) << {
                type: website['rel'],
                website: website['href']
              }
            end
            if entry['gContact$website'].try(:first).try(:[],"rel") == "profile"
              contact[:id] = contact_id(entry['gContact$website'].first.try(:[],"href"))
              contact[:profile_picture] = image_url(contact[:id])
            else
              contact[:profile_picture] = image_url_from_email(contact[:email])
            end
          end

          if entry['gContact$event']
            contact[:dates] = []
            entry['gContact$event'].each do |event|
              label = event['rel'] || event['label']
              contact[:dates] = Array(contact[:dates]) << {
                name: label,
                date: birthday(event['gd$when'].try(:[],'startTime'))
              }
            end
          end

          if entry['gContact$birthday']
            entry['gContact$birthday'].each do |birth_day|
              contact[:birthday] = birthday(birth_day.last)
              contact[:birthdays] = Array(contact[:birthdays]) << {
                birthday: birthday(birth_day.last)
              }
            end
          end

          if entry['gd$organization']
            contact[:company] = entry['gd$organization'].try(:first).try(:[],'gd$orgName').try(:[],'$t')
            contact[:position] = entry['gd$organization'].try(:first).try(:[],'gd$orgTitle').try(:[],'$t')
          end

          if entry['gd$im']
            entry['gd$im'].each do |messenger|
              contact[:messenger_ids] = Array(contact[:messenger_ids]) << {
                type:  messenger['protocol'].split('#')[-1].try(:upcase),
                value: messenger['address']
              }
            end
          end

          contact[:notes] = entry['content'].try(:[],'$t')

          contacts << contact if contact[:name]
        end
        contacts.uniq! {|c| c[:email] || c[:profile_picture] || c[:name]}
        contacts
      end

      def image_url gmail_id
        return "https://profiles.google.com/s2/photos/profile/" + gmail_id if gmail_id
      end

      def current_user me, access_token, token_type
        return nil if me.nil?
        me = JSON.parse(me)
        user = {:id => me['id'], :email => me['email'], :name => me['name'], :first_name => me['given_name'],
                :last_name => me['family_name'], :gender => me['gender'], :birthday => birthday(me['birthday']), :profile_picture => image_url(me['id']),
                :access_token => access_token, :token_type => token_type
        }
        user
      end

      def birthday dob
        return nil if dob.nil?
        birthday = dob.split('-')
        return birthday_format(birthday[2], birthday[3], nil) if birthday.size == 4
        return birthday_format(birthday[1], birthday[2], birthday[0]) if birthday.size == 3
      end

      def contact_id(profile_url)
        id = (profile_url.present?) ? File.basename(profile_url) : nil
        id
      end

    end
  end
end
