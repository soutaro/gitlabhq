module Ci
  class Cluster < ActiveRecord::Base
    extend Gitlab::Ci::Model
    include ReactiveCaching

    self.reactive_cache_key = ->(cluster) { [cluster.class.model_name.singular, cluster.project_id, cluster.id] }

    belongs_to :project
    belongs_to :user
    belongs_to :service

    attr_encrypted :password,
       mode: :per_attribute_iv_and_salt,
       insecure_mode: true,
       key: Gitlab::Application.secrets.db_key_base,
       algorithm: 'aes-256-cbc'

    # after_save :clear_reactive_cache!

    def creation_status(access_token)
      with_reactive_cache(access_token) do |operation|
        {
          status: operation[:status],
          status_message: operation[:status_message]
        }
      end
    end

    def calculate_reactive_cache(access_token)
      return { status: 'INTEGRATED' } if service # If it's already done, we don't need to continue the following process

      api_client = GoogleApi::CloudPlatform::Client.new(access_token, nil)
      operation = api_client.projects_zones_operations(gcp_project_id, cluster_zone, gcp_operation_id)

      return { status_message: 'Failed to get a status' } unless operation

      if operation.status == 'DONE'
        # Get cluster details (end point, etc)
        gke_cluster = api_client.projects_zones_clusters_get(
          gcp_project_id, cluster_zone, cluster_name
        )

        return { status_message: 'Failed to get a cluster info on gke' } unless gke_cluster

        # Get k8s token
        token = ''
        KubernetesService.new.tap do |ks|
          ks.api_url = 'https://' + gke_cluster.endpoint
          ks.ca_pem = Base64.decode64(gke_cluster.master_auth.cluster_ca_certificate)
          ks.username = gke_cluster.master_auth.username
          ks.password = gke_cluster.master_auth.password
          secrets = ks.read_secrets
          secrets.each do |secret|
            name = secret.dig('metadata', 'name')
            if /default-token/ =~ name
              token_base64 = secret.dig('data', 'token')
              token = Base64.decode64(token_base64)
              break
            end
          end
        end

        return { status_message: 'Failed to get a default token on kubernetes' } unless token

        # k8s endpoint, ca_cert
        endpoint = 'https://' + gke_cluster.endpoint
        cluster_ca_certificate = Base64.decode64(gke_cluster.master_auth.cluster_ca_certificate)

        begin
          Ci::Cluster.transaction do
            # Update service
            kubernetes_service.attributes = {
              active: true,
              api_url: endpoint,
              ca_pem: cluster_ca_certificate,
              namespace: project_namespace,
              token: token
            }

            kubernetes_service.save!

            # Save info in cluster record
            update(
              enabled: true,
              service: kubernetes_service,
              username: gke_cluster.master_auth.username,
              password: gke_cluster.master_auth.password,
              token: token,
              ca_cert: cluster_ca_certificate,
              endpoint: endpoint,
            )
          end
        rescue ActiveRecord::RecordInvalid => exception
          return { status_message: 'Failed to setup integration' }
        end
      end

      operation.to_h
    end

    def kubernetes_service
      @kubernetes_service ||= project.find_or_initialize_service('kubernetes')
    end
  end
end
