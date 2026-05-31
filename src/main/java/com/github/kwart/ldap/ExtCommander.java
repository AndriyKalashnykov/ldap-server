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
 *
 */

package com.github.kwart.ldap;

import java.util.ResourceBundle;

import com.beust.jcommander.DefaultUsageFormatter;
import com.beust.jcommander.JCommander;

/**
 * Small extension to JCommander that wraps the rendered usage output with an
 * optional head and tail (program description above the option list, examples
 * below it). JCommander 1.82 moved usage rendering out of {@link JCommander}
 * itself into pluggable {@link DefaultUsageFormatter} subclasses; this class
 * registers an inner formatter that calls the standard renderer and prepends /
 * appends the wrapped strings.
 *
 * @author Josef Cacek
 */
public class ExtCommander extends JCommander {

    private String usageHead;
    private String usageTail;

    public ExtCommander() {
        super();
        setUsageFormatter(new ExtUsageFormatter());
    }

    public ExtCommander(Object object, ResourceBundle bundle, String... args) {
        super(object, bundle, args);
        setUsageFormatter(new ExtUsageFormatter());
    }

    public ExtCommander(Object object, ResourceBundle bundle) {
        super(object, bundle);
        setUsageFormatter(new ExtUsageFormatter());
    }

    public ExtCommander(Object object, String... args) {
        // JCommander(Object, String...) is deprecated (it parses in the ctor);
        // the non-deprecated path is construct-then-parse. super(object) only
        // registers the object, so set the formatter before parse() and parse
        // args explicitly — behaviourally identical to the deprecated ctor.
        super(object);
        setUsageFormatter(new ExtUsageFormatter());
        parse(args);
    }

    public ExtCommander(Object object) {
        super(object);
        setUsageFormatter(new ExtUsageFormatter());
    }

    /** Inner formatter — wraps {@link DefaultUsageFormatter#usage(StringBuilder, String)}. */
    private final class ExtUsageFormatter extends DefaultUsageFormatter {
        ExtUsageFormatter() {
            super(ExtCommander.this);
        }

        @Override
        public void usage(StringBuilder out, String indent) {
            final int indentCount = indent.length();
            if (usageHead != null) {
                out.append(wrap(indentCount, usageHead)).append("\n");
            }
            super.usage(out, indent);
            if (usageTail != null) {
                out.append("\n").append(wrap(indentCount, usageTail));
            }
        }
    }

    private String getIndent(int count) {
        final StringBuilder result = new StringBuilder();
        for (int i = 0; i < count; i++) {
            result.append(" ");
        }
        return result.toString();
    }

    String wrap(final int indent, final String text) {
        final int max = getColumnSize();
        final String[] lines = text.split("\n", -1);
        final String indentStr = getIndent(indent);

        final StringBuilder sb = new StringBuilder();
        for (String line : lines) {
            final String[] words = line.split(" ", -1);
            final StringBuilder lineSb = new StringBuilder();
            for (String word : words) {
                final int lineLength = lineSb.length();
                if (lineLength > 0) {
                    if (indent + lineLength + word.length() > max) {
                        sb.append(indentStr).append(lineSb).append("\n");
                        lineSb.delete(0, lineSb.length());
                    } else {
                        lineSb.append(" ");
                    }
                }
                lineSb.append(word);
            }
            sb.append(lineSb);
            sb.append("\n");
        }
        return sb.toString();
    }

    public String getUsageHead() {
        return usageHead;
    }

    public void setUsageHead(String usageHead) {
        this.usageHead = usageHead;
    }

    public String getUsageTail() {
        return usageTail;
    }

    public void setUsageTail(String usageTail) {
        this.usageTail = usageTail;
    }

}
