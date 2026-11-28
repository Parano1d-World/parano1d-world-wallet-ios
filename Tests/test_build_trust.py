import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('fetch_node',Path(__file__).resolve().parents[1]/'Scripts/fetch-node-parameters.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class BuildTrustTests(unittest.TestCase):
    def test_mac_system_ca_is_validated_before_using_it(self):
        with patch.dict(os.environ,{},clear=True),patch.object(Path,'is_file',return_value=True),patch.object(module.ssl,'create_default_context') as context:
            module.configure_trust('darwin')
            context.assert_called_once_with(cafile='/etc/ssl/cert.pem')
            self.assertEqual(os.environ['SSL_CERT_FILE'],'/etc/ssl/cert.pem')
    def test_explicit_trust_configuration_is_preserved(self):
        for key in ['SSL_CERT_FILE','SSL_CERT_DIR']:
            with patch.dict(os.environ,{key:'/chosen/trust'},clear=True),patch.object(module.ssl,'create_default_context') as context:
                module.configure_trust('darwin')
                context.assert_not_called();self.assertEqual(os.environ[key],'/chosen/trust')
    def test_missing_bundle_does_not_disable_verification(self):
        with patch.dict(os.environ,{},clear=True),patch.object(Path,'is_file',return_value=False):
            module.configure_trust('darwin');self.assertNotIn('SSL_CERT_FILE',os.environ)
    def test_invalid_bundle_fails_without_unverified_fallback(self):
        with patch.dict(os.environ,{},clear=True),patch.object(Path,'is_file',return_value=True),patch.object(module.ssl,'create_default_context',side_effect=ValueError('bad certificate')):
            with self.assertRaises(ValueError):module.configure_trust('darwin')
            self.assertNotIn('SSL_CERT_FILE',os.environ)
if __name__=='__main__':unittest.main()
