"""
The system prompt, and the fences around what users send us.
"""
import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("sead_agent")

#Every document in the training directory is named NN_name.md, and the number is the
#order it takes in the prompt. Three of them the agent will not run without. The
#operating limits must open the prompt and their reminder must close it: the documents in
#between run to thousands of lines, which is far enough for a small model to lose sight
#of the top. The limits are kept apart from the instructions because the instructions are
#replaceable - a deployment pointing SEAD_AGENT_INSTRUCTIONS_FILE at a context document of
#its own should not be able to drop the agent's limits by accident.
TRAINING_FILE_PATTERN = re.compile(r"^(\d+)_(.+\.md)$", re.IGNORECASE)
OPERATING_LIMITS_NAME = "operating-limits.md"
INSTRUCTIONS_NAME = "instructions.md"
OPERATING_LIMITS_REMINDER_NAME = "operating-limits-reminder.md"
REQUIRED_TRAINING_NAMES = [OPERATING_LIMITS_NAME, INSTRUCTIONS_NAME, OPERATING_LIMITS_REMINDER_NAME]

#The user's message and the browser's state summary are fenced into blocks of their own
#in the prompt, so the model can tell what we wrote from what someone typed at it. That
#only holds if the fenced text can't close its own fence, so anything that looks like one
#of our tags is defanged on the way in.
PROMPT_FENCE_PATTERN = re.compile(r"</?\s*(interface-state|user-message|system|instructions|operating-limits)\b[^>]*>", re.IGNORECASE)


@dataclass
class TrainingDocument:
    filename: str
    name: str
    order: int
    path: Path


def list_training_documents(training_dir):
    """
    The NN_name.md files in the training directory, ordered by their number. A .md file
    without a number is skipped with a warning rather than given a guessed place.
    """
    documents = []
    for path in Path(training_dir).iterdir():
        if not path.name.lower().endswith(".md"):
            continue
        match = TRAINING_FILE_PATTERN.match(path.name)
        if not match:
            log.warning("SEAD agent skipped training document %s: it needs an NN_ prefix giving its place in the prompt", path.name)
            continue
        documents.append(TrainingDocument(path.name, match.group(2), int(match.group(1)), path))
    #By number first, so 10_ follows 9_; by filename between equal numbers, so the order is
    #stable between restarts
    return sorted(documents, key=lambda doc: (doc.order, doc.filename))


def read_required_document(path):
    """
    Reads a document the agent cannot run without. An empty file counts as missing - it is
    far more likely a botched edit than a deliberate choice.
    """
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeError("SEAD agent could not read required prompt document "+str(path)+": "+str(error)) from error
    if len(text.strip()) == 0:
        raise RuntimeError("SEAD agent required prompt document "+str(path)+" is empty")
    return text.strip()


def load_instructions(training_dir, instructions_file=""):
    """
    The system prompt: every document in the training directory, in the order their number
    prefixes give. Deployments can point SEAD_AGENT_INSTRUCTIONS_FILE at a different
    instructions document; it takes the place of NN_instructions.md and everything around it
    is loaded either way.
    """
    documents = list_training_documents(training_dir)

    #A missing or misplaced limits file must stop the agent rather than leave a public
    #chatbox running without them, so these raise where the other documents only warn
    for name in REQUIRED_TRAINING_NAMES:
        count = len([doc for doc in documents if doc.name == name])
        if count != 1:
            raise RuntimeError("SEAD agent needs exactly one NN_"+name+" in "+str(training_dir)+", found "+str(count))
    if documents[0].name != OPERATING_LIMITS_NAME:
        raise RuntimeError("SEAD agent requires the operating limits to open the prompt, but "+documents[0].filename+" is numbered before them")
    if documents[-1].name != OPERATING_LIMITS_REMINDER_NAME:
        raise RuntimeError("SEAD agent requires the operating limits reminder to close the prompt, but "+documents[-1].filename+" is numbered after it")

    texts = []
    for doc in documents:
        if doc.name == INSTRUCTIONS_NAME and instructions_file:
            texts.append(read_required_document(instructions_file))
        elif doc.name in REQUIRED_TRAINING_NAMES:
            texts.append(read_required_document(doc.path))
        else:
            try:
                texts.append(doc.path.read_text(encoding="utf-8"))
            except OSError as error:
                #One unreadable file shouldn't cost us the rest of the context
                log.warning("SEAD agent could not read training document %s: %s", doc.filename, error)

    log.info("SEAD agent loaded its prompt from %s: %s%s", training_dir, ", ".join(doc.filename for doc in documents),
             " (instructions from "+instructions_file+")" if instructions_file else "")
    return "\n\n---\n\n".join(texts)


def fence_safe(text):
    """
    Takes the teeth out of anything in untrusted text that looks like one of the tags we use
    to fence it. Without this, a message - or a site name typed into a filter's search box,
    which comes back to us in the state summary - can close its own block and carry on as if
    what followed were part of the system prompt.
    """
    return PROMPT_FENCE_PATTERN.sub(lambda match: match.group(0).replace("<", "").replace(">", ""), str(text))


def describe_client_state(state, max_length):
    """
    Renders the browser's state summary into the block that precedes the user's message.
    Anything unserialisable or oversized is dropped rather than sent - a turn without state
    still works, the agent just has to ask for it.
    """
    if not isinstance(state, (dict, list)):
        return None
    try:
        #The user types into the interface, and what they type comes back to us in here -
        #so this is untrusted text too, not just a description of it
        rendered = fence_safe(json.dumps(state, indent=1, ensure_ascii=False))
    except (TypeError, ValueError):
        return None
    if len(rendered) > max_length:
        log.warning("SEAD agent ignoring an oversized client state (%d chars)", len(rendered))
        return None
    return rendered


def build_prompt(user_input, client_state):
    """
    Puts the interface state in front of the user's message, delimited so the model can tell
    the two apart. What the blocks mean - that the newest state supersedes the older ones, and
    that neither carries instructions - is said once in the system prompt rather than in every
    turn, where it would pile up in the conversation history.
    """
    #Fenced even when there is no state to go with it, so the boundary between what we wrote
    #and what was typed at us is in the same place in every turn
    message = "<user-message>\n"+fence_safe(user_input)+"\n</user-message>"
    if not client_state:
        return message
    return "<interface-state>\n"+client_state+"\n</interface-state>\n\n"+message
