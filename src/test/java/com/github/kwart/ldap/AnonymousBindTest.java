/*
 *  Licensed to the Apache Software Foundation (ASF) under one
 *  or more contributor license agreements.  See the NOTICE file
 *  distributed with this work for additional information
 *  regarding copyright ownership.  The ASF licenses this file
 *  to you under the Apache License, Version 2.0 (the
 *  "License"); you may not use this file except in compliance
 *  with the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing,
 *  software distributed under the License is distributed on an
 *  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 *  KIND, either express or implied.  See the License for the
 *  specific language governing permissions and limitations
 *  under the License.
 */

package com.github.kwart.ldap;

import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Properties;

import javax.naming.Context;
import javax.naming.NamingEnumeration;
import javax.naming.directory.SearchControls;
import javax.naming.directory.SearchResult;
import javax.naming.ldap.InitialLdapContext;
import javax.naming.ldap.LdapContext;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * Covers the {@code --allow-anonymous} (-a) CLI flag, which drives
 * {@code directoryService.setAllowAnonymousAccess(...)}. With the flag set, an
 * anonymous bind (no principal / credentials) may search the directory; this
 * test asserts the bundled example entry is returned over an anonymous bind.
 */
public class AnonymousBindTest {

    private LdapServer ldapServer;

    @BeforeEach
    public void before() throws Exception {
        // -a enables anonymous access; no LDIF arg => the bundled
        // ldap-example.ldif (dc=ldap,dc=example with uid=jduke) is loaded.
        String[] args = new String[] { "-a" };
        CLIArguments cliArguments = new CLIArguments();
        new ExtCommander(cliArguments, args);
        ldapServer = new LdapServer(cliArguments);
    }

    @AfterEach
    public void after() throws Exception {
        ldapServer.stop();
    }

    @Test
    public void testAnonymousSearchFindsSeededEntry() throws Exception {
        Properties env = new Properties();
        env.put(Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
        env.put(Context.PROVIDER_URL, "ldap://127.0.0.1:10389");
        // Anonymous bind: authentication "none", no principal/credentials.
        env.put(Context.SECURITY_AUTHENTICATION, "none");

        LdapContext ctx = new InitialLdapContext(env, null);
        try {
            SearchControls controls = new SearchControls();
            controls.setSearchScope(SearchControls.SUBTREE_SCOPE);
            NamingEnumeration<SearchResult> results =
                    ctx.search("dc=ldap,dc=example", "(uid=jduke)", controls);
            assertTrue(results.hasMore(), "anonymous search should find uid=jduke when --allow-anonymous is set");
            results.close();
        } finally {
            ctx.close();
        }
    }
}
