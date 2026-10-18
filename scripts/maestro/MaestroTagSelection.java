import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;

import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Selects Maestro flows by tag exactly the way `maestro test <directory>` does
 * (maestro.orchestra.workspace.WorkspaceExecutionPlanner), for a caller that
 * hands Maestro one flow file at a time and therefore never gets that
 * filtering from Maestro itself.
 *
 * Run with the Java source launcher against the Maestro CLI's own lib/
 * directory, so the YAML is read by the same Jackson YAML parser Maestro uses:
 *
 *   java -cp "<maestro>/lib/*" MaestroTagSelection.java \
 *       <workspace-config-or-empty> <include-csv> <exclude-csv> <flow>...
 *
 * Semantics (Maestro 2.x):
 *   - effective include = include-csv + workspace config includeTags
 *   - effective exclude = exclude-csv + workspace config excludeTags
 *   - a flow is selected when (include is empty or it has any include tag)
 *     and (it has no exclude tag), so exclude wins over include.
 *   - a flow's tags are the `tags:` list of its config section, the YAML
 *     document before the first `---`.
 *
 * Prints the selected flows, one per line, in input order, on stdout. Any
 * unreadable workspace config or flow config section fails the whole run with
 * a non-zero exit, never a silent "not selected".
 */
public class MaestroTagSelection {

    private static final YAMLFactory YAML = new YAMLFactory();
    private static final ObjectMapper MAPPER = new ObjectMapper(YAML);

    static final class SelectionError extends Exception {
        SelectionError(String message) {
            super(message);
        }
    }

    public static void main(String[] args) {
        try {
            System.exit(run(args));
        } catch (SelectionError e) {
            System.err.println("::error::" + e.getMessage());
            System.exit(1);
        }
    }

    private static int run(String[] args) throws SelectionError {
        if (args.length < 3) {
            throw new SelectionError("usage: MaestroTagSelection <workspace-config-or-empty> <include-csv> <exclude-csv> <flow>...");
        }
        Set<String> include = new LinkedHashSet<>(splitCsv(args[1]));
        Set<String> exclude = new LinkedHashSet<>(splitCsv(args[2]));
        if (!args[0].isEmpty()) {
            JsonNode config = readFirstDocument(new File(args[0]), "maestro-config");
            if (config != null && !config.isNull() && !config.isMissingNode()) {
                if (!config.isObject()) {
                    throw new SelectionError("maestro-config '" + args[0] + "' is not a YAML mapping, so its includeTags/excludeTags cannot be read.");
                }
                include.addAll(workspaceTags(config.get("includeTags"), args[0], "includeTags"));
                exclude.addAll(workspaceTags(config.get("excludeTags"), args[0], "excludeTags"));
            }
        }

        StringBuilder selected = new StringBuilder();
        int selectedCount = 0;
        int total = args.length - 3;
        for (int i = 3; i < args.length; i++) {
            String flow = args[i];
            List<String> tags = flowTags(flow);
            boolean included = include.isEmpty() || tags.stream().anyMatch(include::contains);
            boolean excluded = tags.stream().anyMatch(exclude::contains);
            if (included && !excluded) {
                selected.append(flow).append('\n');
                selectedCount++;
            } else {
                System.err.println("Deselected by tags: " + flow + " (tags: " + tags + ")");
            }
        }
        System.err.println("Maestro tag selection: include " + include + ", exclude " + exclude + "; "
            + selectedCount + " of " + total + " flow(s) selected.");
        System.out.print(selected);
        System.out.flush();
        return 0;
    }

    private static List<String> splitCsv(String csv) {
        List<String> out = new ArrayList<>();
        for (String part : csv.split(",")) {
            String tag = part.trim();
            if (!tag.isEmpty()) {
                out.add(tag);
            }
        }
        return out;
    }

    private static JsonNode readFirstDocument(File file, String what) throws SelectionError {
        if (!file.isFile()) {
            throw new SelectionError(what + " '" + file + "' is not a file.");
        }
        try (JsonParser parser = YAML.createParser(file)) {
            return MAPPER.readTree(parser);
        } catch (Exception e) {
            throw new SelectionError(what + " '" + file + "' is not parsable YAML: " + oneLine(e.getMessage()));
        }
    }

    private static List<String> workspaceTags(JsonNode node, String config, String key) throws SelectionError {
        List<String> out = new ArrayList<>();
        if (node == null || node.isNull()) {
            return out;
        }
        if (node.isValueNode()) {
            out.add(node.asText());
            return out;
        }
        if (!node.isArray()) {
            throw new SelectionError("maestro-config '" + config + "' " + key + " must be a tag or a list of tags.");
        }
        for (JsonNode item : node) {
            if (item.isNull() || !item.isValueNode()) {
                throw new SelectionError("maestro-config '" + config + "' " + key + " must contain only scalar tags.");
            }
            out.add(item.asText());
        }
        return out;
    }

    private static List<String> flowTags(String flow) throws SelectionError {
        JsonNode config = readFirstDocument(new File(flow), "flow");
        if (config == null || !config.isObject()) {
            throw new SelectionError("flow '" + flow + "' does not start with a config section (a YAML mapping before the first '---'), so its tags cannot be read; Maestro itself rejects such a flow.");
        }
        List<String> out = new ArrayList<>();
        JsonNode tags = config.get("tags");
        if (tags == null || tags.isNull()) {
            return out;
        }
        if (!tags.isArray()) {
            throw new SelectionError("flow '" + flow + "' tags must be a YAML list (e.g. 'tags: [smoke]' or a '- smoke' block list); Maestro rejects any other form.");
        }
        for (JsonNode item : tags) {
            if (item.isNull() || !item.isValueNode()) {
                throw new SelectionError("flow '" + flow + "' tags must contain only scalar tags.");
            }
            out.add(item.asText());
        }
        return out;
    }

    private static String oneLine(String message) {
        return message == null ? "(no detail)" : message.replaceAll("\\s+", " ").trim();
    }
}
