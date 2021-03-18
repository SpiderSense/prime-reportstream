package gov.cdc.prime.router.secrets

internal object EnvVarSecretService : SecretService() {
    override fun fetchSecretFromStore(secretName: String): String? {
        return System.getenv(secretName)
    }
}