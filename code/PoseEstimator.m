classdef PoseEstimator < handle
    
     properties (GetAccess = public, SetAccess = public)
        
        num_parts = 4
        num_x_buckets = 20
        num_y_buckets = 20
        num_theta_buckets = 10
        num_scale_buckets = 5
        model_len = [160, 95, 95, 65, 65, 60];
        
        %[x, y, theta, scale], scale: [0, 2.0]
        ideal_parameters
        step_size
        
        %define the order to calculate energy
        table_set_order
        child_relation
        parent_relation
        energy_map
        match_cost_cache
        
        %need to be tuned
        %[variable X partNum X partNum]
        deform_cost_weights
        match_cost_weights = 1
        
        
        %define energy functions
        match_cost = @match_energy_cost
        
        %image info
        image_dir = '../buffy_s5e2_original/';
        all_names
        seq
        img_height
        img_width
        
     end
     
     methods (Access = public)
         function obj = PoseEstimator(ideal_parameters, table_set_order, child_relation, deform_cost_weights)
            
            all_names = dir(obj.image_dir);
            obj.all_names = containers.Map();
            counter = 0;
            for n = 1: numel(all_names)
                if length(all_names(n).name) ~= 10
                    continue
                else
                    counter = counter + 1;
                    obj.all_names(all_names(n).name) = counter;
                end
            end
            obj.table_set_order = table_set_order;
            obj.child_relation = child_relation;
            obj.parent_relation = cell(numel(obj.child_relation), 1);
            %get parent order             
            for i = 1: numel(obj.child_relation)
                for c = 1: numel(obj.child_relation{i})
                    obj.parent_relation{obj.child_relation{i}(c)} = ...
                        [obj.parent_relation{obj.child_relation{i}(c)}, i];
                end
            end
            obj.num_parts = numel(ideal_parameters);
            obj.deform_cost_weights = zeros(4, obj.num_parts, obj.num_parts);
            
            obj.deform_cost_weights = deform_cost_weights;
            
            obj.ideal_parameters = ideal_parameters;
            for j  = 1: 4
                obj.ideal_parameters{j} = zeros(length(ideal_parameters{j}));
                if j ~= 3
                    for p = 1: numel(child_relation)
                        for c = 1: numel(child_relation{p})
                            if j == 4 %scale
                                obj.ideal_parameters{j}(p, child_relation{p}(c)) = ...
                                    ideal_parameters{child_relation{p}(c)}(j) / ideal_parameters{p}(j);
                            else
                                obj.ideal_parameters{j}(p, child_relation{p}(c)) = ...
                                    ideal_parameters{child_relation{p}(c)}(j) - ideal_parameters{p}(j);
                            end
                        end
                    end
                end
            end
            
            %cell array, one cell for a part, a long map, 500000
            %Mapping: mat2str(l_parent)->[min_energy, best_location]
            obj.energy_map = cell(numel(obj.ideal_parameters), 1);
            for i = 1: numel(obj.ideal_parameters)
                obj.energy_map{i} = containers.Map();
            end
            
            %initialize match cost cache
            obj.match_cost_cache = cell(numel(obj.ideal_parameters),1);
            for j = 1:numel(obj.match_cost_cache)
                obj.match_cost_cache{j} = containers.Map();
            end
         end
         
         function cost = deformCost(obj, part_p, part_c, lp, lc)
            x_diff = obj.deform_cost_weights(1, part_p, part_c) * ...
                abs(lc(1) - lp(1) - obj.ideal_parameters{1}(part_p, part_c));
            y_diff = obj.deform_cost_weights(2, part_p, part_c) * ...
                abs(lc(2) - lp(2) - obj.ideal_parameters{2}(part_p, part_c));
            theta_diff = obj.deform_cost_weights(3, part_p, part_c) * ...
                abs(lc(3) - lp(3) - obj.ideal_parameters{3}(part_p, part_c));
            scale_diff = obj.deform_cost_weights(4, part_p, part_c) * ...
                abs(log(lc(4)) - log(lp(4)) - log(obj.ideal_parameters{4}(part_p, part_c)));
            cost = x_diff + y_diff + theta_diff + scale_diff;
         end
         
         function energy = calcEnergy(obj, self_part_idx, l_self, ...
                                      parent_part_idx, l_parent)
             %check invalid location
             if sum(l_self([1, 2, 4]) > 0) ~= 3 ...
                || l_self(3) < -pi ...
                || l_self(1) > obj.img_width ...
                || l_self(2) > obj.img_height ...
                || l_self(3) > pi ...
                || l_self(4) > 2
                energy = inf;
                return;
             end
             %pairwise
             if parent_part_idx
                 pair_wise_energy = obj.deformCost(parent_part_idx, ...
                                                  self_part_idx, ...
                                                  l_parent, ...
                                                  l_self);
             else
                 pair_wise_energy = 0;
             end
             
             %children
             children_energy = 0;
             for c = 1: numel(obj.child_relation{self_part_idx})
                assert(obj.energy_map(obj.child_relation{self_part_idx}(c)). ...
                    isKey(mat2str(l_self)), 'Havent done children parts');
                energy_pair = obj.energy_map{obj.child_relation{self_part_idx}(c)}(mat2str(l_self));
                children_energy = children_energy + energy_pair(0);
             end
             
             %match
             if(~isKey(obj.match_cost_cache{self_part_idx},mat2str(l_self)))
                 obj.match_cost_cache{self_part_idx}(mat2str(l_self)) = ...
                 match_energy_cost(l_self, self_part_idx, obj.seq);
             end
             match_energy = obj.match_cost_cache{self_part_idx}(mat2str(l_self));
             
             %total
             energy = pair_wise_energy + obj.match_cost_weights * match_energy + children_energy;
         end
         
         function [current_min_energy, current_min] = localMin(obj, self_part_idx, parent_part_idx, l_parent)            
            %{
            init_idx = [randi([1, obj.num_x_buckets]), ...
                        randi([1, obj.num_x_buckets]), 1, 1];
                        %randi([1, obj.num_theta_buckets]), ...
                        %randi([1, obj.num_scale_buckets])];
            current_min = 0.5 * obj.step_size + (init_idx - 1) .* obj.step_size;
             %}
            current_min = l_parent;
            current_min_energy = obj.calcEnergy(self_part_idx, current_min, parent_part_idx, l_parent);            
            while true                
                neighbors1 = repmat(current_min, [4, 1]) - eye(4) .* diag(obj.step_size);
                neighbors2 = repmat(current_min, [4, 1]) + eye(4) .* diag(obj.step_size);
                all_neighbors = [neighbors1; neighbors2];
                energies = zeros(9, 1);
                for i = 2: 9
                    energies(i) = obj.calcEnergy(self_part_idx, all_neighbors(i - 1, :), parent_part_idx, l_parent);
                end
                energies(1) = current_min_energy; %min return first element when equal
                [current_min_energy, best_idx] = min(energies);
                
                if best_idx > 1
                    current_min = all_neighbors(best_idx - 1, :);
                else
                    %current_min
                    %l_parent
                    return;
                end
            end            
         end
         
         function updateEnergymap(obj, part_idx)
            xs = (obj.step_size(1) / 2): obj.step_size(1): obj.img_width;
            ys = (obj.step_size(2) / 2): obj.step_size(2): obj.img_height;
            thetas = (-pi + (obj.step_size(3) / 2)): obj.step_size(3): pi;
            scales = (obj.step_size(4) / 2): obj.step_size(4): 2;
            all_combos = combvec(xs(1: obj.num_x_buckets), ...
                                 ys(1: obj.num_y_buckets), ...
                                 thetas(1: obj.num_theta_buckets), ...
                                 scales(1: obj.num_scale_buckets)).';
                             
            for i = 1: size(all_combos, 1)
                fprintf('Part: %d, possiblility %d/%d\n', part_idx, i, ...
                    obj.num_x_buckets * obj.num_y_buckets * obj.num_theta_buckets * obj.num_scale_buckets);                
                [temp_min_energy, temp_min] = ...
                    obj.localMin(part_idx, obj.parent_relation{part_idx}, all_combos(i, :));                
                obj.energy_map{part_idx}(mat2str(all_combos(i, :))) = ...
                    [temp_min_energy, temp_min];
            end
         end
         
         function parts = estimate(obj, seq)
            obj.seq = obj.all_names(seq);
            img = imread(fullfile(obj.image_dir, seq));
            [obj.img_height, obj.img_width, ~] = size(img);
            obj.step_size = [floor(obj.img_width / obj.num_x_buckets), ...
                             floor(obj.img_height / obj.num_y_buckets), ...
                             (2 * pi) / obj.num_theta_buckets, 2 / obj.num_scale_buckets];
            
            %forward calculate energies
            for i = 1: numel(obj.table_set_order)
                obj.updateEnergymap(obj.table_set_order(i));
            end
             
            %backward return optimal values for parts
            parts = zeros(obj.num_parts, 4);
            for j = numel(obj.table_set_order): -1: 1
                % not backtrace yet
                if sum(parts(obj.table_set_order(j), :) == 0) == 4
                    %not root
                    if obj.parent_relation{obj.table_set_order(j)}
                        temp = obj.energy_map{obj.table_set_order(j)} ...
                            (mat2str(parts(obj.parent_relation{obj.table_set_order(j)}, :)));
                        parts(obj.table_set_order(j), :) = temp(2: 5);
                    else%root
                        vals = values(obj.energy_map{obj.table_set_order(j)});
                        [~, idx] = min(vals(:, 5));
                        all_keys = keys(obj.energy_map{obj.table_set_order(j)});
                        parts(obj.table_set_order(j), :) = eval(all_keys(idx));
                    end
                end
                %find the child of this part
                for c = 1: numel(obj.child_relation{obj.table_set_order{j}})
                    child_part_idx = obj.child_relation{obj.table_set_order{j}}(c);
                    temp = obj.energy_map{child_part_idx} ...
                            (mat2str(parts(obj.table_set_order(j), :)));
                    parts(child_part_idx, :) = temp(2: 5);
                end
            end
         end
         
         function coor = changeBase(obj, location, part_idx)
            stick_len = location(4) * obj.model_len(part_idx);
            dx = 0.5 * stick_len * cos(location(3));
            dy = 0.5 * stick_len * sin(location(3));
            if location(3) > 0
                coor = location()
            else
            end
         end
         
         function reset(obj)
            obj.energy_map = cell(numel(obj.ideal_parameters), 1);
            for i = 1: numel(obj.ideal_parameters)
                obj.energy_map{i} = containers.Map('ValueType', 'any');
                obj.match_cost_cache{i} = containers.Map('ValueType', 'any');
            end
         end
     end
end