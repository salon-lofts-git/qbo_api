require 'qbo_api/version'
require 'json'
require 'uri'
require 'securerandom'
require 'logger'
require 'faraday'
require 'faraday_middleware'
require 'faraday/detailed_logger'
require_relative 'qbo_api/configuration'
require_relative 'qbo_api/supporting'
require_relative 'qbo_api/error'
require_relative 'qbo_api/raise_http_exception'
require_relative 'qbo_api/entity'
require_relative 'qbo_api/util'

class QboApi
  extend Configuration
  include Supporting
  include Entity
  include Util
  attr_reader :realm_id

  REQUEST_TOKEN_URL          = 'https://oauth.intuit.com/oauth/v1/get_request_token'
  ACCESS_TOKEN_URL           = 'https://oauth.intuit.com/oauth/v1/get_access_token'
  APP_CENTER_BASE            = 'https://appcenter.intuit.com'
  APP_CENTER_URL             =  APP_CENTER_BASE + '/Connect/Begin?oauth_token='
  V3_ENDPOINT_BASE_URL       = 'https://sandbox-quickbooks.api.intuit.com/v3/company/'
  PAYMENTS_API_BASE_URL      = 'https://sandbox.api.intuit.com/quickbooks/v4/payments'
  APP_CONNECTION_URL         = APP_CENTER_BASE + '/api/v1/connection'

  def initialize(token:, token_secret:, realm_id:, consumer_key: CONSUMER_KEY, 
                 consumer_secret: CONSUMER_SECRET, endpoint: :accounting)
    @consumer_key = consumer_key
    @consumer_secret = consumer_secret
    @token = token
    @token_secret = token_secret
    @realm_id = realm_id
    @endpoint = endpoint
  end

  def connection(url: get_endpoint)
    Faraday.new(url: url) do |faraday|
      faraday.headers['Content-Type'] = 'application/json;charset=UTF-8'
      faraday.headers['Accept'] = "application/json"
      faraday.request :oauth, oauth_data 
      faraday.request :url_encoded
      faraday.use FaradayMiddleware::RaiseHttpException
      faraday.response :detailed_logger, QboApi.logger if QboApi.log
      faraday.adapter  Faraday.default_adapter
    end
  end

  def query(query, params: nil)
    path = "#{realm_id}/query?query=#{CGI.escape(query)}"
    entity = extract_entity_from_query(query, to_sym: true)
    request(:get, entity: entity, path: path, params: params)
  end

  def get(entity, id, params: nil)
    path = "#{entity_path(entity)}/#{id}"
    request(:get, entity: entity, path: path, params: params)
  end

  def create(entity, payload:, params: nil)
    request(:post, entity: entity, path: entity_path(entity), payload: payload, params: params)
  end

  def update(entity, id:, payload:, params: nil)
    payload.merge!(set_update(entity, id))
    request(:post, entity: entity, path: entity_path(entity), payload: payload, params: params)
  end

  def delete(entity, id:)
    err_msg = "Delete is only for transaction entities. Use .deactivate instead"
    raise QboApi::NotImplementedError.new, err_msg unless is_transaction_entity?(entity)
    path = add_params_to_path(path: entity_path(entity), params: { operation: :delete })
    payload = set_update(entity, id)
    request(:post, entity: entity, path: path, payload: payload)
  end

  def deactivate(entity, id:)
    err_msg = "Deactivate is only for name list entities. Use .delete instead"
    raise QboApi::NotImplementedError.new, err_msg unless is_name_list_entity?(entity)
    payload = set_update(entity, id).merge('sparse': true, 'Active': false)
    request(:post, entity: entity, path: entity_path(entity), payload: payload)
  end

  # TODO: Need specs for disconnect and reconnect
  # https://developer.intuit.com/docs/0100_quickbooks_online/0100_essentials/0085_develop_quickbooks_apps/0004_authentication_and_authorization/oauth_management_api#/Reconnect
  def disconnect
    path = "#{APP_CONNECTION_URL}/disconnect"
    request(:get, path: path)
  end

  def reconnect
    path = "#{APP_CONNECTION_URL}/reconnect"
    request(:get, path: path)
  end

  def all(entity, max: 1000, select: nil, inactive: false, &block)
    select = build_all_query(entity, select: select, inactive: inactive)
    pos = 0
    begin
      pos = pos == 0 ? pos + 1 : pos + max
      results = query("#{select} MAXRESULTS #{max} STARTPOSITION #{pos}")
      results.each do |entry|
        yield(entry)
      end if results
    end while (results ? results.size == max : false)
  end

  def request(method, path:, entity: nil, payload: nil, params: nil, headers: nil)
    raw_response = connection.send(method) do |req|
      req.headers['Request-Id'] = headers&.with_indifferent_access&.fetch("requestId", nil) || uuid
      path = finalize_path(path, method: method, params: params)
      case method
      when :get, :delete
        req.url path
      when :post, :put
        req.url path
        req.body = JSON.generate(payload)
      end
    end
    response(raw_response, entity: entity)
  end

  def response(resp, entity: nil)
    data = JSON.parse(resp.body)
    if entity
      entity_response(data, entity)
    else
      data
    end
  rescue => e
    # Catch fetch key errors and just return JSON
    data
  end

  private

  def entity_response(data, entity)
    if qr = data['QueryResponse']
      qr.empty? ? nil : qr.fetch(singular(entity))
    else
      data.fetch(singular(entity))
    end
  end

  def oauth_data
    {
      consumer_key: @consumer_key,
      consumer_secret: @consumer_secret,
      token: @token,
      token_secret: @token_secret
    }
  end

  def set_update(entity, id)
    resp = get(entity, id)
    { Id: resp['Id'], SyncToken: resp['SyncToken'] }
  end

  def get_endpoint
    prod = self.class.production
    case @endpoint
    when :accounting
      prod ? V3_ENDPOINT_BASE_URL.sub("sandbox-", '') : V3_ENDPOINT_BASE_URL
    when :payments
      prod ? PAYMENTS_API_BASE_URL.sub("sandbox.", '') : PAYMENTS_API_BASE_URL
    end
  end

end
