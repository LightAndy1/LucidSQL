use std::fs::File;
use std::io::BufReader;
use std::sync::Arc;
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::verify_server_cert_signed_by_trust_anchor;
use rustls::crypto::{ring, verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::server::ParsedCertificate;
use rustls::{ClientConfig, DigitallySignedStruct, Error as TlsError, RootCertStore, SignatureScheme};
use rustls_pki_types::{CertificateDer, ServerName, UnixTime};
use tokio_postgres::config::SslMode as PgSslMode;
use tokio_postgres::{CancelToken, NoTls};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::error::LucidError;
use super::ConnectionConfig;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LucidSslMode {
    Disable,
    Prefer,
    Require,
    VerifyCa,
    VerifyFull,
}

impl LucidSslMode {
    pub fn parse(raw: &str) -> Result<Self, LucidError> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "disable" => Ok(Self::Disable),
            "prefer" => Ok(Self::Prefer),
            "require" => Ok(Self::Require),
            "verify-ca" => Ok(Self::VerifyCa),
            "verify-full" => Ok(Self::VerifyFull),
            other => Err(LucidError::ConnectionFailed {
                reason: format!(
                    "Unsupported SSL mode '{}'. Valid modes: disable, prefer, require, verify-ca, verify-full.",
                    other
                ),
            }),
        }
    }

    pub fn to_pg_ssl_mode(self) -> PgSslMode {
        match self {
            Self::Disable => PgSslMode::Disable,
            Self::Prefer => PgSslMode::Prefer,
            Self::Require | Self::VerifyCa | Self::VerifyFull => PgSslMode::Require,
        }
    }
}

fn ring_provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

/// TLS verifier for PostgreSQL `prefer` and `require` modes:
/// encrypts traffic cleanly while permitting self-signed/untrusted certificates
/// (never checks CA trust or hostname, matching PostgreSQL libpq `sslmode=require`).
#[derive(Debug)]
struct NoCertVerification {
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for NoCertVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// TLS verifier for PostgreSQL `verify-ca` mode:
/// validates certificate chain signature, EKU, and validity timestamps against trusted root CAs
/// WITHOUT enforcing server hostname match (matching PostgreSQL libpq `sslmode=verify-ca`).
#[derive(Debug)]
struct VerifyCaOnlyVerifier {
    roots: Arc<RootCertStore>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for VerifyCaOnlyVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        let cert = ParsedCertificate::try_from(end_entity)?;
        verify_server_cert_signed_by_trust_anchor(
            &cert,
            &self.roots,
            intermediates,
            now,
            self.provider.signature_verification_algorithms.all,
        )?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn load_root_cert_store(ssl_root_cert: Option<&str>) -> Result<RootCertStore, LucidError> {
    let mut store = RootCertStore::empty();

    if let Some(raw_path) = ssl_root_cert.map(str::trim).filter(|s| !s.is_empty()) {
        let file = File::open(raw_path).map_err(|e| LucidError::ConnectionFailed {
            reason: format!("Unable to open SSL root certificate file '{}': {}", raw_path, e),
        })?;
        let mut reader = BufReader::new(file);
        let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut reader)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| LucidError::ConnectionFailed {
                reason: format!("Failed reading PEM certificate from '{}': {}", raw_path, e),
            })?;

        if certs.is_empty() {
            return Err(LucidError::ConnectionFailed {
                reason: format!("No valid PEM CA certificates found in '{}'.", raw_path),
            });
        }

        let (added, _) = store.add_parsable_certificates(certs);
        if added == 0 {
            return Err(LucidError::ConnectionFailed {
                reason: format!("Failed to parse CA certificate(s) in '{}'.", raw_path),
            });
        }
        return Ok(store);
    }

    let native = rustls_native_certs::load_native_certs();
    let (added, _) = store.add_parsable_certificates(native.certs);
    if added == 0 {
        let err_detail = native
            .errors
            .first()
            .map(|e| format!(": {}", e))
            .unwrap_or_default();
        return Err(LucidError::ConnectionFailed {
            reason: format!(
                "No trusted system root certificates available for TLS verification{}.",
                err_detail
            ),
        });
    }

    Ok(store)
}

pub fn build_rustls_connect(
    mode: LucidSslMode,
    ssl_root_cert: Option<&str>,
) -> Result<Option<MakeRustlsConnect>, LucidError> {
    let provider = ring_provider();
    match mode {
        LucidSslMode::Disable => Ok(None),
        LucidSslMode::Prefer | LucidSslMode::Require => {
            let client_config = ClientConfig::builder_with_provider(Arc::clone(&provider))
                .with_safe_default_protocol_versions()
                .map_err(|e| LucidError::ConnectionFailed {
                    reason: format!("TLS protocol configuration failed: {}", e),
                })?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(NoCertVerification { provider }))
                .with_no_client_auth();
            Ok(Some(MakeRustlsConnect::new(client_config)))
        }
        LucidSslMode::VerifyCa => {
            let roots = Arc::new(load_root_cert_store(ssl_root_cert)?);
            let client_config = ClientConfig::builder_with_provider(Arc::clone(&provider))
                .with_safe_default_protocol_versions()
                .map_err(|e| LucidError::ConnectionFailed {
                    reason: format!("TLS protocol configuration failed: {}", e),
                })?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(VerifyCaOnlyVerifier {
                    roots,
                    provider,
                }))
                .with_no_client_auth();
            Ok(Some(MakeRustlsConnect::new(client_config)))
        }
        LucidSslMode::VerifyFull => {
            let roots = Arc::new(load_root_cert_store(ssl_root_cert)?);
            let client_config = ClientConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .map_err(|e| LucidError::ConnectionFailed {
                    reason: format!("TLS protocol configuration failed: {}", e),
                })?
                .with_root_certificates(roots)
                .with_no_client_auth();
            Ok(Some(MakeRustlsConnect::new(client_config)))
        }
    }
}

#[derive(Clone, Debug)]
pub struct CancelTlsTarget {
    pub ssl_mode: LucidSslMode,
    pub ssl_root_cert: Option<String>,
}

impl CancelTlsTarget {
    pub fn disable() -> Self {
        Self {
            ssl_mode: LucidSslMode::Disable,
            ssl_root_cert: None,
        }
    }

    pub fn from_config(config: &ConnectionConfig) -> Result<Self, LucidError> {
        Ok(Self {
            ssl_mode: LucidSslMode::parse(&config.ssl_mode)?,
            ssl_root_cert: config.ssl_root_cert.clone(),
        })
    }

    pub async fn cancel_with_timeout(
        &self,
        token: &CancelToken,
        timeout: Duration,
    ) -> Result<bool, LucidError> {
        let connector = build_rustls_connect(self.ssl_mode, self.ssl_root_cert.as_deref())?;
        let cancel_fut = async {
            match connector {
                Some(tls) => token.cancel_query(tls).await,
                None => token.cancel_query(NoTls).await,
            }
        };

        match tokio::time::timeout(timeout, cancel_fut).await {
            Ok(Ok(())) => Ok(true),
            Ok(Err(e)) => {
                let msg = format_error_chain(&e);
                let lower = msg.to_ascii_lowercase();
                if lower.contains("broken pipe")
                    || lower.contains("connection refused")
                    || lower.contains("connection reset")
                    || lower.contains("closed")
                {
                    Ok(false)
                } else {
                    Err(LucidError::DatabaseError {
                        code: "57014".into(),
                        message: format!("Failed to send query cancellation packet: {}", msg),
                        detail: None,
                    })
                }
            }
            Err(_) => Err(LucidError::QueryTimedOut {
                duration_ms: timeout.as_millis() as u64,
            }),
        }
    }
}

pub fn format_error_chain(err: &dyn std::error::Error) -> String {
    let mut parts = vec![err.to_string()];
    let mut current = err.source();
    while let Some(src) = current {
        let s = src.to_string();
        if !parts.last().is_some_and(|prev| prev == &s) {
            parts.push(s);
        }
        current = src.source();
    }
    parts.join(": ")
}

pub fn map_postgres_connect_error(err: &tokio_postgres::Error) -> LucidError {
    if let Some(db_err) = err.as_db_error() {
        let code = db_err.code().code();
        let lower_msg = db_err.message().to_ascii_lowercase();
        let is_tls_hba_reject = lower_msg.contains("no encryption") || lower_msg.contains("ssl");
        if code == "28P01" || (code == "28000" && !is_tls_hba_reject) {
            let mut msg = db_err.message().to_string();
            if let Some(detail) = db_err.detail() {
                msg.push_str(&format!(" ({})", detail));
            }
            return LucidError::AuthenticationFailed { message: msg };
        }
    }
    LucidError::ConnectionFailed {
        reason: format_error_chain(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::connection::{
        close_session, execute_session_script, get_or_create_session, ManagedPool,
    };
    use crate::query::execute::cancel_active_query;
    use crate::query::CellValue;

    fn find_binary(name: &str) -> PathBuf {
        let candidates = [
            format!("/opt/homebrew/opt/postgresql@16/bin/{}", name),
            format!("/opt/homebrew/bin/{}", name),
            format!("/usr/local/bin/{}", name),
            format!("/usr/bin/{}", name),
        ];
        for path in candidates {
            let pb = PathBuf::from(&path);
            if pb.exists() {
                return pb;
            }
        }
        PathBuf::from(name)
    }

    fn pick_free_port() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        listener.local_addr().unwrap().port()
    }

    struct TlsPgFixture {
        root_dir: PathBuf,
        data_dir: PathBuf,
        ca_cert_path: PathBuf,
        other_ca_cert_path: PathBuf,
        port: u16,
        user: String,
        password: String,
        pg_ctl: PathBuf,
    }

    impl TlsPgFixture {
        fn start() -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root_dir = std::env::temp_dir().join(format!("lucidsql_tls_fixture_{}", unique));
            let data_dir = root_dir.join("data");
            std::fs::create_dir_all(&root_dir).unwrap();

            let initdb = find_binary("initdb");
            let pg_ctl = find_binary("pg_ctl");
            let openssl = find_binary("openssl");

            let user = "lucid_tls_user".to_string();
            let password = "Str0ng!TlsPassword#99".to_string();
            let pw_file = root_dir.join("pwfile");
            std::fs::write(&pw_file, format!("{}\n", password)).unwrap();

            let init_out = Command::new(&initdb)
                .args([
                    "-D",
                    data_dir.to_str().unwrap(),
                    "-U",
                    &user,
                    "-A",
                    "scram-sha-256",
                    "--pwfile",
                    pw_file.to_str().unwrap(),
                    "-E",
                    "UTF8",
                    "--no-locale",
                ])
                .output()
                .expect("run initdb");
            assert!(
                init_out.status.success(),
                "initdb failed: {}",
                String::from_utf8_lossy(&init_out.stderr)
            );

            // Generate CA 1 (signed server cert for localhost), CA 2 (unrelated CA for negative verify-ca)
            let ca_key = root_dir.join("ca.key");
            let ca_cert_path = root_dir.join("ca.crt");
            let server_key = root_dir.join("server.key");
            let server_csr = root_dir.join("server.csr");
            let server_cert = root_dir.join("server.crt");
            let ext_file = root_dir.join("ext.cnf");
            let other_ca_key = root_dir.join("other_ca.key");
            let other_ca_cert_path = root_dir.join("other_ca.crt");

            std::fs::write(
                &ext_file,
                "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nsubjectAltName=DNS:localhost\n",
            )
            .unwrap();

            for args in [
                vec![
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-days",
                    "7",
                    "-nodes",
                    "-keyout",
                    ca_key.to_str().unwrap(),
                    "-out",
                    ca_cert_path.to_str().unwrap(),
                    "-subj",
                    "/CN=LucidSQL-Test-CA",
                ],
                vec![
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-days",
                    "7",
                    "-nodes",
                    "-keyout",
                    other_ca_key.to_str().unwrap(),
                    "-out",
                    other_ca_cert_path.to_str().unwrap(),
                    "-subj",
                    "/CN=Unrelated-CA",
                ],
                vec![
                    "req",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    server_key.to_str().unwrap(),
                    "-out",
                    server_csr.to_str().unwrap(),
                    "-subj",
                    "/CN=localhost",
                ],
                vec![
                    "x509",
                    "-req",
                    "-in",
                    server_csr.to_str().unwrap(),
                    "-CA",
                    ca_cert_path.to_str().unwrap(),
                    "-CAkey",
                    ca_key.to_str().unwrap(),
                    "-CAcreateserial",
                    "-out",
                    server_cert.to_str().unwrap(),
                    "-days",
                    "7",
                    "-extfile",
                    ext_file.to_str().unwrap(),
                ],
            ] {
                let out = Command::new(&openssl).args(&args).output().expect("openssl");
                assert!(
                    out.status.success(),
                    "openssl {:?} failed: {}",
                    args,
                    String::from_utf8_lossy(&out.stderr)
                );
            }

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mut perms = std::fs::metadata(&server_key).unwrap().permissions();
                perms.set_mode(0o600);
                std::fs::set_permissions(&server_key, perms).unwrap();
            }

            // Copy certs into data_dir with postgresql.conf pointing to them
            let pg_cert = data_dir.join("server.crt");
            let pg_key = data_dir.join("server.key");
            std::fs::copy(&server_cert, &pg_cert).unwrap();
            std::fs::copy(&server_key, &pg_key).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mut perms = std::fs::metadata(&pg_key).unwrap().permissions();
                perms.set_mode(0o600);
                std::fs::set_permissions(&pg_key, perms).unwrap();
            }

            let port = pick_free_port();
            let conf_path = data_dir.join("postgresql.conf");
            let mut conf = std::fs::read_to_string(&conf_path).unwrap();
            conf.push_str(&format!(
                "\nlisten_addresses = '127.0.0.1'\nport = {}\nssl = on\nssl_cert_file = '{}'\nssl_key_file = '{}'\nunix_socket_directories = ''\npassword_encryption = 'scram-sha-256'\n",
                port,
                pg_cert.to_string_lossy(),
                pg_key.to_string_lossy()
            ));
            std::fs::write(&conf_path, conf).unwrap();

            let hba_path = data_dir.join("pg_hba.conf");
            std::fs::write(
                &hba_path,
                "local all all scram-sha-256\nhostssl all all 127.0.0.1/32 scram-sha-256\nhostssl all all ::1/128 scram-sha-256\n",
            )
            .unwrap();

            let log_path = root_dir.join("postgres.log");
            let start_out = Command::new(&pg_ctl)
                .args([
                    "-D",
                    data_dir.to_str().unwrap(),
                    "-l",
                    log_path.to_str().unwrap(),
                    "-w",
                    "start",
                ])
                .output()
                .expect("start pg_ctl");
            assert!(
                start_out.status.success(),
                "pg_ctl start failed: {} {}",
                String::from_utf8_lossy(&start_out.stderr),
                std::fs::read_to_string(&log_path).unwrap_or_default()
            );

            Self {
                root_dir,
                data_dir,
                ca_cert_path,
                other_ca_cert_path,
                port,
                user,
                password,
                pg_ctl,
            }
        }

        fn config(&self, host: &str, ssl_mode: &str, ssl_root_cert: Option<&Path>) -> ConnectionConfig {
            ConnectionConfig {
                host: host.into(),
                port: self.port,
                database: "postgres".into(),
                user: self.user.clone(),
                password: Some(self.password.clone()),
                ssl_mode: ssl_mode.into(),
                ssl_root_cert: ssl_root_cert.map(|p| p.to_string_lossy().into_owned()),
                timeout_seconds: 5,
            }
        }
    }

    impl Drop for TlsPgFixture {
        fn drop(&mut self) {
            let _ = Command::new(&self.pg_ctl)
                .args(["-D", self.data_dir.to_str().unwrap(), "-m", "immediate", "stop"])
                .output();
            let _ = std::fs::remove_dir_all(&self.root_dir);
        }
    }

    #[test]
    fn test_ssl_mode_parsing_rejects_unknown_without_downgrade() {
        assert_eq!(LucidSslMode::parse("disable").unwrap(), LucidSslMode::Disable);
        assert_eq!(LucidSslMode::parse(" PREFER ").unwrap(), LucidSslMode::Prefer);
        assert_eq!(LucidSslMode::parse("require").unwrap(), LucidSslMode::Require);
        assert_eq!(LucidSslMode::parse("Verify-CA").unwrap(), LucidSslMode::VerifyCa);
        assert_eq!(LucidSslMode::parse("verify-full").unwrap(), LucidSslMode::VerifyFull);
        assert!(matches!(
            LucidSslMode::parse("allow-insecure"),
            Err(LucidError::ConnectionFailed { .. })
        ));
    }

    #[tokio::test]
    async fn test_password_auth_tls_modes_and_cancel_against_ephemeral_pg() {
        let fixture = TlsPgFixture::start();

        // 1. disable must fail against hostssl-only server (no silent upgrade/downgrade mismatch)
        let disable_pool = ManagedPool::new(&fixture.config("127.0.0.1", "disable", None)).unwrap();
        assert!(matches!(
            disable_pool.get().await,
            Err(LucidError::ConnectionFailed { .. })
        ));

        // 2. Wrong password over TLS must report AuthenticationFailed (not generic ConnectionFailed)
        let mut wrong_pw = fixture.config("127.0.0.1", "require", None);
        wrong_pw.password = Some("definitely-wrong-password".into());
        let wrong_pool = ManagedPool::new(&wrong_pw).unwrap();
        assert!(matches!(
            wrong_pool.get().await,
            Err(LucidError::AuthenticationFailed { .. })
        ));

        // 3. prefer & require connect encrypted with self-signed cert
        for mode in ["prefer", "require"] {
            let cfg = fixture.config("127.0.0.1", mode, None);
            let pool = ManagedPool::new(&cfg).unwrap();
            let client = pool.get().await.expect(mode);
            let ssl_active: bool = client
                .query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", &[])
                .await
                .unwrap()
                .get(0);
            assert!(ssl_active, "mode {} should negotiate TLS", mode);
        }

        // 4. verify-ca rejects untrusted/wrong CA, accepts matching custom CA even when host=127.0.0.1 differs from CN=localhost
        let bad_ca_pool = ManagedPool::new(&fixture.config(
            "127.0.0.1",
            "verify-ca",
            Some(&fixture.other_ca_cert_path),
        ))
        .unwrap();
        assert!(matches!(
            bad_ca_pool.get().await,
            Err(LucidError::ConnectionFailed { .. })
        ));

        let good_ca_ip_pool = ManagedPool::new(&fixture.config(
            "127.0.0.1",
            "verify-ca",
            Some(&fixture.ca_cert_path),
        ))
        .unwrap();
        assert!(good_ca_ip_pool.get().await.is_ok());

        // 5. verify-full rejects hostname mismatch (127.0.0.1 vs SAN DNS:localhost) and accepts localhost
        let mismatch_pool = ManagedPool::new(&fixture.config(
            "127.0.0.1",
            "verify-full",
            Some(&fixture.ca_cert_path),
        ))
        .unwrap();
        assert!(matches!(
            mismatch_pool.get().await,
            Err(LucidError::ConnectionFailed { .. })
        ));

        let verify_full_cfg = fixture.config("localhost", "verify-full", Some(&fixture.ca_cert_path));
        let full_pool = ManagedPool::new(&verify_full_cfg).unwrap();
        let full_client = full_pool.get().await.expect("verify-full with localhost");
        let cipher_row = full_client
            .query_one("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", &[])
            .await
            .unwrap();
        assert!(cipher_row.get::<_, bool>(0));

        // 6. Dedicated session & TLS cancellation
        let sid = "tls-session-cancel-test";
        let qid = "tls-query-cancel-test";
        get_or_create_session(&verify_full_cfg, sid, false)
            .await
            .expect("dedicated TLS session");

        let cfg_clone = verify_full_cfg.clone();
        let query_handle = tokio::spawn(async move {
            execute_session_script(
                &cfg_clone,
                sid,
                "SELECT pg_sleep(5);",
                qid,
                None,
                false,
            )
            .await
        });

        tokio::time::sleep(Duration::from_millis(250)).await;
        let cancelled = cancel_active_query(qid).await.expect("TLS cancel call");
        assert!(cancelled, "TLS query cancellation should reach PostgreSQL backend");

        let query_res = query_handle.await.unwrap();
        assert!(matches!(query_res, Err(LucidError::QueryCancelled)));

        // Verify password-authenticated query result over TLS works after cancel
        let ok_res = execute_session_script(
            &verify_full_cfg,
            sid,
            "SELECT 123 AS ok;",
            "tls-query-ok",
            None,
            false,
        )
        .await
        .unwrap();
        assert_eq!(ok_res.rows[0].cells[0], CellValue::Integer(123));

        close_session(sid).await.unwrap();
    }
}
