-- v0.96e · Security advisor «function_search_path_mutable» on two v0.96c helpers (fixed search_path, no behaviour change).
alter function fabula.notify_topic_for(text, text, text) set search_path = fabula, public;
alter function fabula.notify_due(text, time, time) set search_path = fabula, public;
